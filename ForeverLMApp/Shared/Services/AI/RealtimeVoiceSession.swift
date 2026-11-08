#if os(iOS)
import AVFoundation
#endif
import Foundation
import OSLog
import WebRTC

/// One voice conversation's connection to OpenAI Realtime, over WebRTC, the way
/// OpenAI's guide connects a phone or desktop client
/// (developers.openai.com/api/docs/guides/voice-webrtc, read 2026-11-07):
///
/// 1. The proxy mints a client secret with the whole session configured on it
///    (`ManagedAI.mintRealtimeVoiceSecret`): instructions, voice, tools, turn
///    detection. Nothing large ever crosses the data channel, whose messages
///    are capped near 256 KB.
/// 2. The microphone is added as a local audio track and the `oai-events`
///    data channel is created, before the offer.
/// 3. The offer's SDP is posted to `https://api.openai.com/v1/realtime/calls`
///    with the secret; the answer's SDP comes back as the body.
///
/// The model's voice then arrives as a remote audio track that WebRTC plays on
/// its own. The server buffers that audio, so it knows what has been heard and
/// trims the rest itself when the learner talks over a reply: there is no
/// client-side playback queue, barge-in or truncation. Echo is cancelled by the
/// platform's voice processing (WebRTC's audio unit on iOS, its own canceller on
/// the Mac). JSON events go both ways on the data channel.
///
/// One session is one call. When it ends (the network, OpenAI's hour limit)
/// the event stream finishes, and the controller opens another.
final class RealtimeVoiceSession: NSObject, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.foreverlm", category: "RealtimeVoiceTransport")
    static let callsURL = URL(string: "https://api.openai.com/v1/realtime/calls")!
    static let eventsChannelLabel = "oai-events"
    /// What the data channel carries in one message. OpenAI's own events stay
    /// far below it; the guard keeps an oversized tool answer from closing the
    /// channel, and the toolboxes keep their answers well inside it.
    static let maximumMessageBytes = 200_000

    /// One factory for the app's lifetime, as WebRTC expects. On iOS the audio
    /// session is set up for voice chat before the factory's audio unit exists.
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        #if os(iOS)
        let configuration = RTCAudioSessionConfiguration.webRTC()
        configuration.category = AVAudioSession.Category.playAndRecord.rawValue
        configuration.mode = AVAudioSession.Mode.voiceChat.rawValue
        // The speaker, not the earpiece, when nothing else is connected;
        // AirPods and CarPlay take the call route.
        configuration.categoryOptions = [.allowBluetoothHFP, .defaultToSpeaker]
        RTCAudioSessionConfiguration.setWebRTC(configuration)
        #endif
        return RTCPeerConnectionFactory()
    }()

    private struct State {
        var peerConnection: RTCPeerConnection?
        var dataChannel: RTCDataChannel?
        var microphone: RTCAudioTrack?
        var continuation: AsyncStream<RealtimeVoiceServerEvent>.Continuation?
        var openWaiter: CheckedContinuation<Void, Error>?
        var isOpen = false
        var isClosed = false
        var sequencer = OpenAIRealtimeResponseSequencer()
        var levelTask: Task<Void, Never>?
        var disconnectTask: Task<Void, Never>?
    }

    private let lock = NSLock()
    private var current = State()

    /// Every read and write of `current`: WebRTC calls back on its own threads.
    private func withState<R>(_ body: (inout State) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&current)
    }
    private let onMicrophoneLevel: @Sendable (Float) -> Void

    init(onMicrophoneLevel: @escaping @Sendable (Float) -> Void) {
        self.onMicrophoneLevel = onMicrophoneLevel
    }

    // MARK: - Connecting

    /// Opens the call and returns its events once the data channel is open.
    /// Throws when OpenAI refuses the offer or the channel does not open.
    func connect(secret: String, microphoneMuted: Bool) async throws -> AsyncStream<RealtimeVoiceServerEvent> {
        let factory = Self.factory
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peerConnection = factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else {
            throw RealtimeVoiceSessionError.notConnected
        }
        // WebRTC's echo canceller, noise suppressor and gain control are on by
        // default for an audio source; said here so nobody wonders.
        let audioConstraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "googEchoCancellation": "true",
                "googNoiseSuppression": "true",
                "googAutoGainControl": "true",
                "googHighpassFilter": "true",
            ],
            optionalConstraints: nil
        )
        let microphone = factory.audioTrack(with: factory.audioSource(with: audioConstraints), trackId: "microphone")
        microphone.isEnabled = !microphoneMuted
        peerConnection.add(microphone, streamIds: ["foreverlm-voice"])
        let channelConfiguration = RTCDataChannelConfiguration()
        channelConfiguration.isOrdered = true
        guard let dataChannel = peerConnection.dataChannel(forLabel: Self.eventsChannelLabel, configuration: channelConfiguration) else {
            peerConnection.close()
            throw RealtimeVoiceSessionError.notConnected
        }
        dataChannel.delegate = self

        let (stream, continuation) = AsyncStream.makeStream(of: RealtimeVoiceServerEvent.self)
        withState {
            $0.peerConnection = peerConnection
            $0.dataChannel = dataChannel
            $0.microphone = microphone
            $0.continuation = continuation
        }

        do {
            let offer = try await Self.offer(peerConnection)
            try await Self.setLocalDescription(offer, on: peerConnection)
            let answer = try await Self.exchange(offer: offer.sdp, secret: secret)
            try await Self.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: answer), on: peerConnection)
            try await waitUntilOpen(timeout: .seconds(20))
        } catch {
            close()
            throw error
        }
        startLevelMeter()
        Self.logger.info("Realtime voice call open")
        return stream
    }

    /// The SDP answer for an offer, from OpenAI's calls endpoint.
    private static func exchange(offer sdp: String, secret: String) async throws -> String {
        var request = URLRequest(url: callsURL, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(sdp.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(status), body.hasPrefix("v=") else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            logger.error("Realtime calls endpoint answered \(status): \(message ?? body.prefix(200).description, privacy: .public)")
            throw RealtimeVoiceSessionError.serverRejected(message ?? "OpenAI could not open the voice call (\(status)).")
        }
        return body
    }

    private func waitUntilOpen(timeout: Duration) async throws {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.resolveOpenWaiter(.failure(RealtimeVoiceSessionError.connectionTimedOut))
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resolved = withState { state -> Result<Void, Error>? in
                if state.isOpen { return .success(()) }
                if state.isClosed { return .failure(RealtimeVoiceSessionError.notConnected) }
                state.openWaiter = continuation
                return nil
            }
            if let resolved { continuation.resume(with: resolved) }
        }
    }

    private func resolveOpenWaiter(_ result: Result<Void, Error>) {
        let waiter = withState { state -> CheckedContinuation<Void, Error>? in
            defer { state.openWaiter = nil }
            return state.openWaiter
        }
        waiter?.resume(with: result)
    }

    // MARK: - Ending

    /// Hangs up. The event stream finishes; nothing is reported as a drop.
    func close() {
        let ended = withState { state -> (RTCPeerConnection?, AsyncStream<RealtimeVoiceServerEvent>.Continuation?)? in
            guard !state.isClosed else { return nil }
            state.isClosed = true
            state.isOpen = false
            state.levelTask?.cancel()
            state.disconnectTask?.cancel()
            let ended = (state.peerConnection, state.continuation)
            state.dataChannel?.delegate = nil
            state.dataChannel?.close()
            state.dataChannel = nil
            state.microphone = nil
            state.peerConnection = nil
            state.continuation = nil
            state.sequencer.reset()
            return ended
        }
        resolveOpenWaiter(.failure(RealtimeVoiceSessionError.notConnected))
        guard let ended else { return }
        ended.1?.finish()
        ended.0?.close()
    }

    /// The call ended on its own: the stream says why, then finishes, which is
    /// how the controller learns to open another.
    private func drop(_ reason: String) {
        let continuation = withState { state -> AsyncStream<RealtimeVoiceServerEvent>.Continuation? in
            guard !state.isClosed else { return nil }
            return state.continuation
        }
        Self.logger.error("Realtime voice call dropped: \(reason, privacy: .public)")
        resolveOpenWaiter(.failure(RealtimeVoiceSessionError.serverRejected(reason)))
        continuation?.yield(.serverError(message: reason))
        close()
    }

    // MARK: - Sending

    func setMicrophoneMuted(_ muted: Bool) {
        withState { $0.microphone?.isEnabled = !muted }
    }

    func createMessage(role: String, text: String) throws {
        try send(OpenAIRealtimeWire.messagePayload(role: role, text: text))
    }

    func createFunctionOutput(callID: String, output: String) throws {
        try send(OpenAIRealtimeWire.functionOutputPayload(callID: callID, output: output))
    }

    /// Asks for a reply, after the one under way if there is one: OpenAI takes
    /// one response at a time, and a tool's answer arrives before its call's
    /// response is done.
    func createResponse() throws {
        if let action = withState({ $0.sequencer.requestCreate() }) {
            try sendResponseControl(action)
        }
    }

    private func sendResponseControl(_ action: OpenAIRealtimeResponseSequencer.Action) throws {
        switch action {
        case .create(let eventID): try send(OpenAIRealtimeWire.responseCreatePayload(eventID: eventID))
        case .cancel: try send(OpenAIRealtimeWire.responseCancelPayload)
        }
    }

    private func send(_ payload: [String: Any]) throws {
        let text = try OpenAIRealtimeWire.encodedText(payload)
        let data = Data(text.utf8)
        guard data.count <= Self.maximumMessageBytes else {
            Self.logger.error("Dropped an oversized realtime event (\(data.count) bytes)")
            throw RealtimeVoiceSessionError.encodingFailed
        }
        let channel = withState { $0.isOpen ? $0.dataChannel : nil }
        guard let channel, channel.sendData(RTCDataBuffer(data: data, isBinary: false)) else {
            throw RealtimeVoiceSessionError.notConnected
        }
    }

    // MARK: - Receiving

    private func receive(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = OpenAIRealtimeWire.decodeServerEvent(json) else { return }
        let action: OpenAIRealtimeResponseSequencer.Action? = withState { state in
            switch json["type"] as? String {
            case "response.created":
                state.sequencer.responseCreated()
                return nil
            case "response.done":
                return state.sequencer.responseDone()
            case "error":
                return OpenAIRealtimeWire.responseCreateErrorEventID(in: json)
                    .flatMap { state.sequencer.responseCreateFailed(eventID: $0) }
            default:
                return nil
            }
        }
        if case .serverError(let message) = event, RealtimeVoiceServerErrorDisposition.isBenign(message) {
            Self.logger.debug("Ignored a benign realtime error: \(message, privacy: .public)")
        } else {
            withState { $0.continuation }?.yield(event)
        }
        if let action { try? sendResponseControl(action) }
    }

    // MARK: - Microphone level

    /// The waveform's level, read from WebRTC's own statistics ten times a
    /// second: the outgoing track's `media-source` carries `audioLevel`, 0...1.
    private func startLevelMeter() {
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let peerConnection = self.withState({ $0.peerConnection }) else { return }
                let report = await peerConnection.statistics()
                let level = report.statistics.values
                    .first { $0.type == "media-source" && ($0.values["kind"] as? String) == "audio" }
                    .flatMap { ($0.values["audioLevel"] as? NSNumber)?.floatValue }
                if let level { self.onMicrophoneLevel(level) }
            }
        }
        withState { $0.levelTask = task }
    }

    // MARK: - Promise wrappers

    private static func offer(_ peerConnection: RTCPeerConnection) async throws -> RTCSessionDescription {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "false"],
            optionalConstraints: nil
        )
        return try await withCheckedThrowingContinuation { continuation in
            peerConnection.offer(for: constraints) { description, error in
                if let description {
                    continuation.resume(returning: description)
                } else {
                    continuation.resume(throwing: error ?? RealtimeVoiceSessionError.notConnected)
                }
            }
        }
    }

    private static func setLocalDescription(_ description: RTCSessionDescription, on peerConnection: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setLocalDescription(description) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func setRemoteDescription(_ description: RTCSessionDescription, on peerConnection: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setRemoteDescription(description) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}

// MARK: - WebRTC callbacks

extension RealtimeVoiceSession: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        switch dataChannel.readyState {
        case .open:
            withState { $0.isOpen = true }
            resolveOpenWaiter(.success(()))
        case .closed:
            drop("The voice call's event channel closed.")
        default:
            break
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard !buffer.isBinary else { return }
        receive(buffer.data)
    }
}

extension RealtimeVoiceSession: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        switch newState {
        case .failed:
            drop("The voice call's connection failed.")
        case .disconnected:
            // ICE often comes back from a brief loss (a lift, a Wi-Fi hand-off)
            // on its own; only a loss that lasts is a drop.
            let task = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                self?.drop("The voice call lost its connection.")
            }
            withState {
                $0.disconnectTask?.cancel()
                $0.disconnectTask = task
            }
        case .connected:
            withState {
                $0.disconnectTask?.cancel()
                $0.disconnectTask = nil
            }
        default:
            break
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
