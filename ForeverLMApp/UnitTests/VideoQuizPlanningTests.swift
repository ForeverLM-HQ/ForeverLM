import Foundation
import Testing
@testable import ForeverLM

/// The grader's message and reply check (`VideoQuizPlanning`), used by a
/// course quiz taken in a chat.
@Suite("Quiz Grading")
struct VideoQuizPlanningTests {
    @Test("A moment of a video is stamped m:ss, or h:mm:ss past the hour")
    func timestamps() {
        #expect(VideoQuizPlanning.timestamp(0) == "0:00")
        #expect(VideoQuizPlanning.timestamp(245.9) == "4:05")
        #expect(VideoQuizPlanning.timestamp(3_725) == "1:02:05")
    }

    @Test("Verdicts map onto Memory's schedule")
    func verdicts() {
        #expect(VideoQuizVerdict.correct.scheduleRating == .good)
        #expect(VideoQuizVerdict.partial.scheduleRating == .hard)
        #expect(VideoQuizVerdict.incorrect.scheduleRating == .again)
    }

    // MARK: Grading

    private func message(_ attempt: QuizAnswerAttempt) -> String {
        VideoQuizPlanning.graderMessage(
            question: "What happens to mitophagy without fission, and why?",
            referenceAnswer: "It stops: a mitochondrion must be split off the network first.",
            keyPoints: ["fission comes first"],
            coveredTranscript: "[7:49] Take away fission and there is no mitophagy.",
            attempt: attempt
        )
    }

    @Test("The grader is told whether it may follow the answer up: only a first try the learner can reply to, never twice")
    func graderMessageSaysWhenAFollowUpMayBeAsked() {
        let chat = message(QuizAnswerAttempt(answer: "mitophagy also stops", learnerCanReply: true))
        #expect(chat.contains("Learner's answer: mitophagy also stops"))
        #expect(chat.contains("you may ask one follow-up instead of grading"))
        #expect(chat.contains("Reference answer: It stops"))

        let noReply = message(QuizAnswerAttempt(answer: "mitophagy also stops"))
        #expect(noReply.contains("They cannot reply to a follow-up here: grade the answer as it stands."))
        #expect(!noReply.contains("you may ask one follow-up"))

        let reply = message(QuizAnswerAttempt(
            answer: "mitophagy also stops",
            followUp: .init(question: "Why does it stop?", reply: "it has to be cut off the network"),
            learnerCanReply: true
        ))
        #expect(reply.contains("Your follow-up: Why does it stop?"))
        #expect(reply.contains("Learner's reply: it has to be cut off the network"))
        #expect(reply.contains("Grade the answer and the reply together, as one answer, and ask nothing more."))
        #expect(!reply.contains("you may ask one follow-up"))
    }

    @Test("A grader reply is a grade, a follow-up where one may be asked, or no usable answer")
    func graderReplies() throws {
        let firstTry = QuizAnswerAttempt(answer: "mitophagy also stops", learnerCanReply: true)
        let noReply = QuizAnswerAttempt(answer: "mitophagy also stops")
        let afterFollowUp = QuizAnswerAttempt(
            answer: "mitophagy also stops",
            followUp: .init(question: "Why?", reply: "fission first"),
            learnerCanReply: true
        )
        let followUp = #"{"asks": "what happens and why", "follow_up": "You have what happens. Why does it happen?"}"#
        let partialWithFollowUp = #"{"asks": "…", "verdict": "partial", "feedback": "Half.", "follow_up": "Why does it happen?"}"#
        let correct = #"```json\n{"asks": "…", "verdict": "correct", "feedback": "Right: it stops."}\n```"#

        #expect(try VideoQuizPlanning.graderResult(fromReply: followUp, for: firstTry) == .followUp("You have what happens. Why does it happen?"))
        #expect(try VideoQuizPlanning.graderResult(fromReply: partialWithFollowUp, for: firstTry) == .followUp("Why does it happen?"))
        #expect(try VideoQuizPlanning.graderResult(fromReply: correct, for: firstTry) == .graded(VideoQuizGrade(verdict: .correct, feedback: "Right: it stops.")))
        // Where no follow-up may be asked, only a grade will do.
        #expect(try VideoQuizPlanning.graderResult(fromReply: partialWithFollowUp, for: noReply) == .graded(VideoQuizGrade(verdict: .partial, feedback: "Half.")))
        #expect(try VideoQuizPlanning.graderResult(fromReply: partialWithFollowUp, for: afterFollowUp) == .graded(VideoQuizGrade(verdict: .partial, feedback: "Half.")))
        for attempt in [noReply, afterFollowUp] {
            #expect(throws: AIError.self) { _ = try VideoQuizPlanning.graderResult(fromReply: followUp, for: attempt) }
        }
        for unusable in ["User Safety: safe", "", #"{"verdict": "correct", "feedback": "  "}"#, #"{"verdict": "partly", "feedback": "Half."}"#] {
            #expect(throws: AIError.self, Comment(rawValue: unusable)) {
                _ = try VideoQuizPlanning.graderResult(fromReply: unusable, for: firstTry)
            }
        }
    }

    @Test("A grader reply that is not a grade is asked for again in place, and the next good one is taken")
    func graderAsksAgainAfterAnUnusableReply() async throws {
        QuizGraderStubURLProtocol.reset(replies: [
            "User Safety: safe",
            #"{"asks": "what happens and why", "verdict": "correct", "feedback": "Right."}"#,
        ])
        let service = AIService(session: QuizGraderStubURLProtocol.mockSession())
        var config = AITaskConfig(provider: .anthropic, apiKey: "test-key", model: "claude-sonnet-4-6")
        // The chat's grade: a label no task has, so no backup model is read
        // from this Mac's settings.
        config.taskLabel = QuizGrading.chatTaskLabel
        let lecture = StudioArticle(
            url: "https://example.com/lecture-4", title: "Lecture 4",
            sourceType: .video, discoveryOrigin: .manual, id: "lecture-4"
        )
        let result = try await service.gradeQuizAnswer(
            source: lecture,
            question: "What happens to mitophagy without fission, and why?",
            referenceAnswer: "It stops: a mitochondrion must be split off the network first.",
            keyPoints: [],
            coveredTranscript: "[7:49] Take away fission and there is no mitophagy.",
            attempt: QuizAnswerAttempt(answer: "it stops, since it has to be split off first", learnerCanReply: true),
            config: config
        )
        #expect(result == .graded(VideoQuizGrade(verdict: .correct, feedback: "Right.")))
        #expect(QuizGraderStubURLProtocol.requestCount() == 2, "the reply that was not a grade was asked for again")
        #expect(QuizGraderStubURLProtocol.requestBodies().allSatisfy { $0.contains("they can reply to you") })
    }
}

/// Answers every grader request with the next reply in its queue, in the shape
/// the request's provider path expects, and keeps every request body.
final class QuizGraderStubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String] = []
    nonisolated(unsafe) private static var bodies: [String] = []

    static func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QuizGraderStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func reset(replies: [String]) {
        lock.lock(); self.replies = replies; bodies = []; lock.unlock()
    }

    static func requestCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return bodies.count
    }

    static func requestBodies() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return bodies
    }

    // Every request this session makes is answered here; none reaches a network.
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let bodyText = Self.bodyText(for: request)
        Self.lock.lock()
        Self.bodies.append(bodyText)
        let text = Self.replies.isEmpty ? "" : Self.replies.removeFirst()
        Self.lock.unlock()

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
        let body: String
        if url.path.contains("/anthropic/") {
            body = #"{"content":[{"type":"text","text":\#(escaped)}],"usage":{"input_tokens":10,"output_tokens":10}}"#
        } else {
            body = #"{"choices":[{"message":{"role":"assistant","content":\#(escaped)}}],"usage":{"prompt_tokens":10,"completion_tokens":10}}"#
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyText(for request: URLRequest) -> String {
        if let body = request.httpBody { return String(data: body, encoding: .utf8) ?? "" }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Stop in a quiz's chat, or a queued message sent now, while the grader's
/// model is still writing: the grade must end at once, not when the model
/// finishes. On 2026-09-27 a free model took minutes to run into its token
/// limit, and the chat sat through all of it, because a one-shot call awaited
/// its shared network task's `value`, which outlasts the caller's cancel.
/// Serialized: both tests hold requests in the same stub.
@Suite("One-shot AI call cancellation", .serialized)
struct OneShotCallCancellationTests {
    private var chatGradeConfig: AITaskConfig {
        var config = AITaskConfig(provider: .anthropic, apiKey: "test-key", model: "claude-sonnet-4-6")
        // The chat's grade: a label no task has, so no backup model is read
        // from this Mac's settings.
        config.taskLabel = QuizGrading.chatTaskLabel
        return config
    }

    @Test("Stopping ends a grade its model is still writing, and stops the request", .timeLimit(.minutes(1)))
    func stoppingEndsAGradeStillBeingWritten() async throws {
        HeldReplyURLProtocol.reset(reply: #"{"verdict": "correct", "feedback": "Right."}"#)
        let service = AIService(session: HeldReplyURLProtocol.mockSession())
        let config = chatGradeConfig
        let lecture = StudioArticle(
            url: "https://example.com/lecture-4", title: "Lecture 4",
            sourceType: .video, discoveryOrigin: .manual, id: "lecture-4"
        )
        let grading = Task {
            try await service.gradeQuizAnswer(
                source: lecture,
                question: "What happens to mitophagy without fission, and why?",
                referenceAnswer: "It stops: a mitochondrion must be split off the network first.",
                keyPoints: [],
                coveredTranscript: "[7:49] Take away fission and there is no mitophagy.",
                attempt: QuizAnswerAttempt(answer: "it stops", learnerCanReply: true),
                config: config
            )
        }
        try await HeldReplyURLProtocol.waitUntil { started, _ in started == 1 }
        grading.cancel()
        let result = await grading.result
        guard case .failure(let error) = result, AITransientErrorClassifier.isCancellation(error) else {
            Issue.record("expected the grade to end as cancelled, got \(result)")
            return
        }
        // No one reads the reply any more, so the request is stopped too.
        try await HeldReplyURLProtocol.waitUntil { _, stopped in stopped == 1 }
        #expect(HeldReplyURLProtocol.counts().started == 1, "a stopped grade is not asked for again")
    }

    @Test("One caller giving up leaves the other caller of an identical call its answer", .timeLimit(.minutes(1)))
    func sharedCallOutlivesOneCallerGivingUp() async throws {
        HeldReplyURLProtocol.reset(reply: "Protons leak back through the membrane.")
        let service = AIService(session: HeldReplyURLProtocol.mockSession())
        let config = chatGradeConfig
        func ask() -> Task<String, Error> {
            Task {
                try await service.call(
                    config: config,
                    system: "Answer in one sentence.",
                    user: "Why does the membrane potential fall?",
                    maxTokens: 64
                )
            }
        }
        func waiters() async -> Int {
            await service.oneShotRequestsInFlight.values.first?.waiters.count ?? 0
        }

        let first = ask()
        try await HeldReplyURLProtocol.waitUntil { started, _ in started == 1 }
        let second = ask()
        while await waiters() < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }

        first.cancel()
        let firstResult = await first.result
        guard case .failure(let error) = firstResult, AITransientErrorClassifier.isCancellation(error) else {
            Issue.record("expected the cancelled caller to stop waiting, got \(firstResult)")
            return
        }
        #expect(await waiters() == 1)
        #expect(await service.oneShotRequestsInFlight.values.first?.task.isCancelled == false)

        HeldReplyURLProtocol.releaseAll()
        #expect(try await second.value == "Protons leak back through the membrane.")
        #expect(HeldReplyURLProtocol.counts().started == 1, "both callers shared one request")
        #expect(HeldReplyURLProtocol.counts().stopped == 0)
        #expect(await service.oneShotRequestsInFlight.isEmpty)
    }
}

/// Holds every request until the test releases it, the way a slow model holds
/// a grade, and counts the requests URLSession stopped while they were held.
final class HeldReplyURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var reply = ""
    nonisolated(unsafe) private static var held: [HeldReplyURLProtocol] = []
    nonisolated(unsafe) private static var started = 0
    nonisolated(unsafe) private static var stopped = 0

    static func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldReplyURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func reset(reply: String) {
        lock.lock(); self.reply = reply; held = []; started = 0; stopped = 0; lock.unlock()
    }

    static func counts() -> (started: Int, stopped: Int) {
        lock.lock(); defer { lock.unlock() }
        return (started, stopped)
    }

    /// Polls until `condition` holds; the test's time limit bounds the wait.
    static func waitUntil(_ condition: (_ started: Int, _ stopped: Int) -> Bool) async throws {
        while true {
            let now = counts()
            if condition(now.started, now.stopped) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Answers every request still held.
    static func releaseAll() {
        lock.lock()
        let waiting = held
        held = []
        let text = reply
        lock.unlock()
        for request in waiting { request.answer(text) }
    }

    // Every request this session makes is held here; none reaches a network.
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.started += 1
        Self.held.append(self)
        Self.lock.unlock()
    }

    override func stopLoading() {
        Self.lock.lock()
        if let index = Self.held.firstIndex(where: { $0 === self }) {
            Self.held.remove(at: index)
            Self.stopped += 1
        }
        Self.lock.unlock()
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
        let body: String
        if url.path.contains("/anthropic/") {
            body = #"{"content":[{"type":"text","text":\#(escaped)}],"usage":{"input_tokens":10,"output_tokens":10}}"#
        } else {
            body = #"{"choices":[{"message":{"role":"assistant","content":\#(escaped)}}],"usage":{"prompt_tokens":10,"completion_tokens":10}}"#
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
