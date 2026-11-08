import Foundation
import OSLog

/// One OpenAI Realtime WebSocket and the event stream decoded from it.
///
/// It owns the socket only: the conversation (`RealtimeVoiceController`) decides
/// what to say and what to do when a socket ends. Microphone audio is buffered
/// here until the session acknowledges its configuration, and again while a dead
/// socket is replaced, so nothing the learner says in a gap is lost.
actor RealtimeVoiceSession {
    private static let logger = Logger(subsystem: "com.foreverlm", category: "RealtimeVoiceTransport")
    /// A full minute of 24 kHz mono PCM16. Setup takes seconds; the bound keeps a
    /// stalled socket from growing memory forever.
    private static let maximumBufferedAudioBytes = 24_000 * 2 * 60

    private struct ReadyWaiter {
        let continuation: CheckedContinuation<Void, Error>
        let timeoutTask: Task<Void, Never>
    }

    private var task: URLSessionWebSocketTask?
    private var continuation: AsyncStream<RealtimeVoiceServerEvent>.Continuation?
    private var receiveLoop: Task<Void, Never>?
    private var keepAliveLoop: Task<Void, Never>?
    private var readyTimeoutTask: Task<Void, Never>?
    private var generation = 0
    private var closing = false
    private var isReady = false
    private var readinessFailure: RealtimeVoiceSessionError?
    private var readyWaiters: [UUID: ReadyWaiter] = [:]
    private var buffersAudio = false
    private var bufferedChunks: [Data] = []
    private var bufferedByteCount = 0
    /// While a dead socket is replaced under a live microphone, the buffer drops
    /// its oldest audio instead of throwing: a throw would end the one capture
    /// task, and the replacement would hear nothing for the rest of the talk.
    private var evictsOldestBufferedAudio = false
    private var sequencer = OpenAIRealtimeResponseSequencer()

    // MARK: - Lifecycle

    /// Starts keeping microphone audio before the socket exists, so a tap on
    /// voice listens at once.
    func beginBufferingAudio() {
        readinessFailure = nil
        resetAudioBuffer()
        buffersAudio = true
    }

    /// Opens a socket. Audio kept since `beginBufferingAudio` or since the last
    /// socket died is delivered, in order, once this one is ready.
    func connect(model: String, secret: String) -> AsyncStream<RealtimeVoiceServerEvent> {
        closing = false
        isReady = false
        readinessFailure = nil
        if !buffersAudio {
            resetAudioBuffer()
        }
        sequencer.reset()
        Self.logger.info("Opening realtime voice socket model=\(model, privacy: .public)")

        let (stream, continuation) = AsyncStream.makeStream(of: RealtimeVoiceServerEvent.self)
        self.continuation = continuation
        generation += 1
        let generation = self.generation
        let task = URLSession.shared.webSocketTask(with: OpenAIRealtimeWire.socketRequest(model: model, secret: secret))
        task.maximumMessageSize = 4 * 1024 * 1024
        self.task = task
        task.resume()
        startKeepAlive(task: task, generation: generation)
        startReadyTimeout(generation: generation)
        receiveLoop = Task { [weak self] in
            await self?.runReceiveLoop(task: task, generation: generation)
        }
        return stream
    }

    func configure(instructions: String, tools: [[String: Any]], voice: String, transcriptionModel: String) async throws {
        try await send(OpenAIRealtimeWire.configurationPayload(
            instructions: instructions,
            tools: tools,
            voice: voice,
            transcriptionModel: transcriptionModel
        ))
    }

    /// Nothing but configuration may be sent before the session acknowledges it.
    func waitUntilReady(timeout: Duration = .seconds(20)) async throws {
        if isReady { return }
        if let readinessFailure { throw readinessFailure }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if isReady {
                    continuation.resume()
                    return
                }
                if let readinessFailure {
                    continuation.resume(throwing: readinessFailure)
                    return
                }
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    await self?.expireReadyWaiter(id)
                }
                readyWaiters[id] = ReadyWaiter(continuation: continuation, timeoutTask: timeoutTask)
            }
        } onCancel: {
            Task { await self.cancelReadyWaiter(id) }
        }
    }

    /// Ends the conversation's socket for good.
    func close() {
        tearDownSocket(code: .normalClosure)
        readinessFailure = .notConnected
        failReadyWaiters(RealtimeVoiceSessionError.notConnected)
        resetAudioBuffer()
    }

    /// Ends this socket but keeps the microphone lane: audio that arrives while
    /// the controller opens a replacement is kept, oldest evicted past a minute.
    func closeForReplacement() {
        tearDownSocket(code: .goingAway)
        readinessFailure = nil
        failReadyWaiters(RealtimeVoiceSessionError.notConnected)
        buffersAudio = true
        evictsOldestBufferedAudio = true
    }

    private func tearDownSocket(code: URLSessionWebSocketTask.CloseCode) {
        closing = true
        receiveLoop?.cancel()
        receiveLoop = nil
        keepAliveLoop?.cancel()
        keepAliveLoop = nil
        readyTimeoutTask?.cancel()
        readyTimeoutTask = nil
        task?.cancel(with: code, reason: nil)
        task = nil
        continuation?.finish()
        continuation = nil
        isReady = false
        sequencer.reset()
    }

    // MARK: - Socket

    /// Keeps a quiet socket visible to URLSession and NATs, and finds a dead one
    /// before the learner's next sentence does.
    private func startKeepAlive(task: URLSessionWebSocketTask, generation: Int) {
        keepAliveLoop?.cancel()
        keepAliveLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                await self?.ping(task: task, generation: generation)
            }
        }
    }

    private func startReadyTimeout(generation: Int) {
        readyTimeoutTask?.cancel()
        readyTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            await self?.readinessExpired(generation: generation)
        }
    }

    private func readinessExpired(generation: Int) {
        guard generation == self.generation, !closing, !isReady else { return }
        finishConnection(error: RealtimeVoiceSessionError.connectionTimedOut, generation: generation)
    }

    private func ping(task: URLSessionWebSocketTask, generation: Int) async {
        guard generation == self.generation, !closing else { return }
        let error = await withCheckedContinuation { (continuation: CheckedContinuation<Error?, Never>) in
            // A failing socket can call the pong handler twice, and a second
            // resume is a runtime trap.
            let resumed = OSAllocatedUnfairLock(initialState: false)
            task.sendPing { error in
                let first = resumed.withLock { didResume -> Bool in
                    guard !didResume else { return false }
                    didResume = true
                    return true
                }
                if first { continuation.resume(returning: error) }
            }
        }
        guard let error, generation == self.generation, !closing else { return }
        finishConnection(error: error, generation: generation)
    }

    private func runReceiveLoop(task: URLSessionWebSocketTask, generation: Int) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                let text: String?
                switch message {
                case .string(let string): text = string
                case .data(let data): text = String(data: data, encoding: .utf8)
                @unknown default: text = nil
                }
                guard let text,
                      let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                      let event = OpenAIRealtimeWire.decodeServerEvent(json) else { continue }

                if case .sessionReady = event, !isReady {
                    markReady()
                    if buffersAudio {
                        do {
                            try await flushBufferedAudio()
                        } catch {
                            finishConnection(error: error, generation: generation)
                            return
                        }
                    }
                }
                if case .serverError(let message) = event {
                    switch RealtimeVoiceServerErrorDisposition.resolve(isReady: isReady, message: message) {
                    case .ignore:
                        Self.logger.debug("Ignored a benign realtime error: \(message, privacy: .public)")
                        if let action = observeResponseControl(json) {
                            try? await sendResponseControl(action)
                        }
                        continue
                    case .failReadiness:
                        let failure = RealtimeVoiceSessionError.serverRejected(message)
                        readinessFailure = failure
                        failReadyWaiters(failure)
                    case .surfaceInline:
                        break
                    }
                }
                continuation?.yield(event)

                if let action = observeResponseControl(json) {
                    do {
                        try await sendResponseControl(action)
                    } catch {
                        finishConnection(error: error, generation: generation)
                        return
                    }
                }
            } catch {
                finishConnection(error: error, generation: generation)
                return
            }
        }
    }

    /// A socket ended on its own. The stream finishes, which is how the
    /// controller learns to replace it; a live conversation's microphone keeps
    /// buffering from this instant.
    private func finishConnection(error: Error, generation: Int) {
        guard generation == self.generation, !closing else { return }
        Self.logger.error("Realtime voice socket ended: \(error.localizedDescription, privacy: .public)")
        let hadCompletedSetup = isReady
        continuation?.yield(.serverError(message: error.localizedDescription))
        continuation?.finish()
        continuation = nil
        keepAliveLoop?.cancel()
        keepAliveLoop = nil
        readyTimeoutTask?.cancel()
        readyTimeoutTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isReady = false
        sequencer.reset()
        if hadCompletedSetup {
            buffersAudio = true
            evictsOldestBufferedAudio = true
        } else {
            let failure = (error as? RealtimeVoiceSessionError) ?? .serverRejected(error.localizedDescription)
            readinessFailure = failure
            failReadyWaiters(failure)
        }
    }

    private func markReady() {
        readyTimeoutTask?.cancel()
        readyTimeoutTask = nil
        isReady = true
        readinessFailure = nil
        let waiters = Array(readyWaiters.values)
        readyWaiters.removeAll()
        for waiter in waiters {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume()
        }
    }

    private func failReadyWaiters(_ error: Error) {
        let waiters = Array(readyWaiters.values)
        readyWaiters.removeAll()
        for waiter in waiters {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(throwing: error)
        }
    }

    private func expireReadyWaiter(_ id: UUID) {
        guard readyWaiters[id] != nil else { return }
        let failure = RealtimeVoiceSessionError.connectionTimedOut
        readinessFailure = failure
        failReadyWaiters(failure)
    }

    private func cancelReadyWaiter(_ id: UUID) {
        guard let waiter = readyWaiters.removeValue(forKey: id) else { return }
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(throwing: CancellationError())
    }

    // MARK: - Audio

    func appendAudio(_ pcm16: Data) async throws {
        if buffersAudio {
            var nextByteCount = bufferedByteCount + pcm16.count
            if nextByteCount > Self.maximumBufferedAudioBytes {
                guard evictsOldestBufferedAudio else {
                    throw RealtimeVoiceSessionError.startupAudioBufferExceeded
                }
                while nextByteCount > Self.maximumBufferedAudioBytes, !bufferedChunks.isEmpty {
                    nextByteCount -= bufferedChunks.removeFirst().count
                }
            }
            bufferedChunks.append(pcm16)
            bufferedByteCount = nextByteCount
            return
        }
        guard isReady else { return }
        try await send(OpenAIRealtimeWire.appendAudioPayload(pcm16))
    }

    /// Sends kept audio in order. Chunks that arrive while a send suspends stay
    /// buffered and go in the next pass; the gate drops only once none is left.
    private func flushBufferedAudio() async throws {
        while !bufferedChunks.isEmpty {
            let chunks = bufferedChunks
            bufferedChunks.removeAll(keepingCapacity: true)
            bufferedByteCount = 0
            for chunk in chunks {
                try await send(OpenAIRealtimeWire.appendAudioPayload(chunk))
            }
        }
        buffersAudio = false
        evictsOldestBufferedAudio = false
    }

    private func resetAudioBuffer() {
        buffersAudio = false
        evictsOldestBufferedAudio = false
        bufferedChunks.removeAll(keepingCapacity: false)
        bufferedByteCount = 0
    }

    // MARK: - Conversation items and responses

    func createMessage(role: String, text: String) async throws {
        try await send(OpenAIRealtimeWire.messagePayload(role: role, text: text))
    }

    func createFunctionOutput(callID: String, output: String) async throws {
        try await send(OpenAIRealtimeWire.functionOutputPayload(callID: callID, output: output))
    }

    func createResponse() async throws {
        if let action = sequencer.requestCreate() {
            try await sendResponseControl(action)
        }
    }

    func cancelResponse() async throws {
        if let action = sequencer.requestCancel() {
            try await sendResponseControl(action)
        }
    }

    func truncateItem(itemID: String, audioEndMs: Int) async throws {
        try await send(OpenAIRealtimeWire.truncatePayload(itemID: itemID, audioEndMs: audioEndMs))
    }

    private func observeResponseControl(_ json: [String: Any]) -> OpenAIRealtimeResponseSequencer.Action? {
        switch json["type"] as? String {
        case "response.created":
            sequencer.responseCreated()
            return nil
        case "response.done":
            return sequencer.responseDone()
        case "error":
            guard let eventID = OpenAIRealtimeWire.responseCreateErrorEventID(in: json) else { return nil }
            return sequencer.responseCreateFailed(eventID: eventID)
        default:
            return nil
        }
    }

    private func sendResponseControl(_ action: OpenAIRealtimeResponseSequencer.Action) async throws {
        switch action {
        case .create(let eventID):
            try await send(OpenAIRealtimeWire.responseCreatePayload(eventID: eventID))
        case .cancel:
            try await send(OpenAIRealtimeWire.responseCancelPayload)
        }
    }

    private func send(_ payload: [String: Any]) async throws {
        guard let task else { throw RealtimeVoiceSessionError.notConnected }
        try await task.send(.string(OpenAIRealtimeWire.encodedText(payload)))
    }
}
