@preconcurrency import AVFoundation
import Foundation
import os

enum MobileRealtimeAudioEvent: Sendable {
    case configurationChanged
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case mediaServicesWereReset
    case inputLevel(Float)
    case playbackStarted
    case playbackDrained
    case playbackStalled
}

// Full-duplex audio for voice mode (`RealtimeVoiceController`): one AVAudioEngine
// captures the mic as PCM16 mono for OpenAI Realtime and plays the tutor's PCM16
// replies, both at 24 kHz. Ported from the first realtime voice (removed
// 2026-10-01), where it was hardened against CarPlay and AirPods route changes;
// `MobileRealtimeVoiceAudio` below wraps it for the shared controller.
//
// Echo control comes from AVAudioSession's echo-cancelled built-in input on
// supported phones. On every other built-in-speaker route the capture path is
// half-duplex: mic frames are dropped only while model audio is actually being
// rendered, plus a short room-reverb tail. Headphones and the receiver remain
// full-duplex because their output cannot acoustically feed the built-in mic.
//
// Threading: the input tap fires on a Core Audio thread; every buffer is
// copied and hopped onto `workQueue` before conversion, so the audio thread
// never runs the converter or the capture callback. Mutable state is confined
// to `workQueue`; the few playback fields the controller reads are protected by
// the same queue via sync accessors.
final class MobileRealtimeAudioIO: @unchecked Sendable {
    /// PCM16 mono rate on the wire, both directions.
    static let playbackSampleRate = RealtimeVoiceDefaults.sampleRate
    /// Half-duplex only: how long after the last rendered buffer the
    /// mic stays muted, so room reverb of the model's last word is not captured.
    private static let echoTailSeconds: TimeInterval = 0.2

    private var engine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    private let workQueue = DispatchQueue(label: "com.foreverlm.realtime-audio")
    /// Serializes `start`, `stop`, and `restart`. Every caller runs them on a
    /// detached task, and on 2026-09-05 two of those tasks were inside the
    /// class at once: the controller's `start()` and a recovery `restart()`.
    /// The restart replaced the engine and installed its tap while the start,
    /// already past its own `removeTap`, was about to install one too — and
    /// `installTap` reports a bus that already carries a tap by raising an
    /// Objective-C exception, which aborts the process. `inputTapInstalled`
    /// cannot prevent that; it only records what the last call did. The lock
    /// makes the calls take turns, so each sees the graph the previous one left.
    private let lifecycleLock = NSLock()
    /// Installed and removed with the session; lifecycle calls are serialized
    /// by `lifecycleLock`.
    private var routeObserver: NSObjectProtocol?
    private var sessionObservers: [NSObjectProtocol] = []

    private var playbackFormat = AVAudioFormat(
        standardFormatWithSampleRate: MobileRealtimeAudioIO.playbackSampleRate,
        channels: 1
    )!

    // workQueue-confined; (re)built each start() for the session's capture rate.
    private var apiFormat: AVAudioFormat!
    /// 40 ms of PCM16 mono per append gives server VAD frequent enough
    /// boundaries to react to short utterances and interruptions without a
    /// perceptible packet delay.
    private var captureChunkBytes = 0
    private var captureConverter: AVAudioConverter?
    private var pendingCapture = Data()
    private var onCapturedAudio: (@Sendable (Data) -> Void)?
    private var onAudioEvent: (@Sendable (MobileRealtimeAudioEvent) -> Void)?
    private var configuredCaptureSampleRate = MobileRealtimeAudioIO.playbackSampleRate
    private var configuredPlaybackSampleRate = MobileRealtimeAudioIO.playbackSampleRate
    private var inputTapInstalled = false
    /// True only between a successful `engine.start()` and the next `stop()`.
    /// `AVAudioPlayerNode` raises an uncatchable exception when a buffer is
    /// scheduled on it — or when it is started — while it is detached or its
    /// engine is not running, so every playback call is gated on this.
    private var isGraphRunning = false
    /// Playback progress is derived only from completed buffers. Asking
    /// `AVAudioNode.lastRenderTime` for the live clock can wait for an I/O cycle
    /// while Core Audio is reconfiguring the engine, which blocks whichever
    /// thread asked — on the main thread that is a watchdog termination.
    private var playbackItemGeneration: UInt = 0
    private var completedItemFrames: AVAudioFramePosition = 0
    private var playerStarted = false
    /// Completion count for buffers the speaker has not rendered yet. Unlike
    /// AVAudioPlayerNode's sample clock, this reaches zero when playback drains.
    private var pendingPlaybackBuffers = 0
    private var playbackProgressCheckScheduled = false
    private var didReportPlaybackStall = false
    /// Invalidates completion callbacks from buffers discarded by stop().
    private var playbackGeneration: UInt = 0
    /// An interruption closes playback until the service starts a genuinely
    /// new response. Without this gate, audio deltas already in the WebSocket
    /// pipeline can make the stopped reply begin speaking again.
    private var playbackGate = RealtimePlaybackGate()
    private var captureMutedUntil: TimeInterval = 0
    /// True only for a built-in-speaker route without system echo cancellation.
    private var mutesCaptureDuringPlayback = true
    private var isMicrophoneMuted = false
    private var lastInputLevelEmission: TimeInterval = 0
    /// Lifts the model's replies to podcast loudness on the way to the
    /// speaker. workQueue-confined; re-prepared for each session's playback
    /// rate. See `MobileSpeechLoudness` for the measurements behind it.
    private let speechLoudness = MobileSpeechLoudness()

    // MARK: - Lifecycle

    func start(
        captureSampleRate: Double = MobileRealtimeAudioIO.playbackSampleRate,
        playbackSampleRate: Double = MobileRealtimeAudioIO.playbackSampleRate,
        isMicrophoneMuted: Bool = false,
        onCapturedAudio: @escaping @Sendable (Data) -> Void,
        onAudioEvent: @escaping @Sendable (MobileRealtimeAudioEvent) -> Void = { _ in }
    ) throws {
        try lifecycleLock.withLock {
            try startHoldingLifecycleLock(
                captureSampleRate: captureSampleRate,
                playbackSampleRate: playbackSampleRate,
                isMicrophoneMuted: isMicrophoneMuted,
                onCapturedAudio: onCapturedAudio,
                onAudioEvent: onAudioEvent
            )
        }
    }

    /// The body of `start()`. Callers hold `lifecycleLock`.
    private func startHoldingLifecycleLock(
        captureSampleRate: Double,
        playbackSampleRate: Double,
        isMicrophoneMuted: Bool,
        onCapturedAudio: @escaping @Sendable (Data) -> Void,
        onAudioEvent: @escaping @Sendable (MobileRealtimeAudioEvent) -> Void
    ) throws {
        let input = engine.inputNode
        let audioSession = AVAudioSession.sharedInstance()
        let muteDuringPlayback = Self.requiresHalfDuplexCapture(audioSession)
        let apiFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: captureSampleRate,
            channels: 1,
            interleaved: true
        )!
        // 40 ms of PCM16 mono, two bytes per sample.
        let captureChunkBytes = Int(captureSampleRate * 0.04) * 2
        let playbackFormat = AVAudioFormat(
            standardFormatWithSampleRate: playbackSampleRate,
            channels: 1
        )!

        workQueue.sync {
            self.apiFormat = apiFormat
            self.captureChunkBytes = captureChunkBytes
            self.onCapturedAudio = onCapturedAudio
            self.onAudioEvent = onAudioEvent
            self.configuredCaptureSampleRate = captureSampleRate
            self.configuredPlaybackSampleRate = playbackSampleRate
            self.playbackFormat = playbackFormat
            self.speechLoudness.prepare(sampleRate: playbackSampleRate)
            self.pendingCapture = Data()
            self.playbackItemGeneration &+= 1
            self.completedItemFrames = 0
            self.playerStarted = false
            self.pendingPlaybackBuffers = 0
            self.playbackProgressCheckScheduled = false
            self.didReportPlaybackStall = false
            self.playbackGate = RealtimePlaybackGate()
            self.captureMutedUntil = 0
            self.mutesCaptureDuringPlayback = muteDuringPlayback
            self.isMicrophoneMuted = isMicrophoneMuted
            self.lastInputLevelEmission = 0
        }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: audioSession,
            queue: nil
        ) { [weak self] notification in
            self?.refreshEchoSuppression()
            let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            if Self.routeChangeRequiresGraphRebuild(reason) {
                self?.emit(.configurationChanged)
            }
        }
        installSessionObservers(audioSession)

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)

        // `installTap` raises an Objective-C exception — which Swift cannot
        // catch, so it aborts the process — when the bus already carries a tap.
        // Nothing here refuses a second `start()` over a session that is still
        // up: `inputTapInstalled` records that a tap exists, it does not stop
        // another from being installed over it. Removing first is a no-op on an
        // untapped bus and takes the whole failure mode off the table.
        input.removeTap(onBus: 0)
        workQueue.sync { inputTapInstalled = false }

        // Read the hardware format last, immediately before the tap is
        // installed. Attaching and connecting the player node above can settle
        // the session onto a different route, and AVFAudio raises rather than
        // returns when the format handed to `installTap` no longer matches the
        // node's own.
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw MobileRealtimeAudioError.inputUnavailable
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: apiFormat) else {
            throw MobileRealtimeAudioError.unsupportedInputFormat
        }
        workQueue.sync {
            captureConverter = converter
        }

        input.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            // Copy out of the realtime thread before doing any work.
            guard let copy = Self.copied(buffer) else { return }
            self.workQueue.async { self.convertAndEmit(copy) }
        }
        workQueue.sync { inputTapInstalled = true }

        engine.prepare()
        try engine.start()
        // Only now is the player attached to a running engine. Buffers that
        // arrived while the graph was being rebuilt were dropped rather than
        // scheduled onto a node that would have trapped.
        workQueue.sync { isGraphRunning = true }
    }

    /// True between a successful `start()`/`restart()` and the next `stop()`
    /// or the teardown half of a `restart()`. The controller reads it to decide
    /// whether a transport-only recovery may keep this graph.
    var isRunning: Bool {
        workQueue.sync { isGraphRunning }
    }

    func stop() {
        lifecycleLock.withLock {
            stopHoldingLifecycleLock(clearConfiguration: true)
        }
    }

    /// Rebuilds the engine after an AVAudioSession interruption or media-
    /// services reset while preserving the ordered capture sink. The whole
    /// sequence — read the configuration, tear down, rebuild, start — runs
    /// under one hold of the lock, so a `start()` or `stop()` racing it sees
    /// either the old graph or the new one, never the gap between.
    func restart(recreateGraph: Bool = false) throws {
        try lifecycleLock.withLock {
            let configuration = workQueue.sync {
                (configuredCaptureSampleRate, configuredPlaybackSampleRate, isMicrophoneMuted, onCapturedAudio, onAudioEvent)
            }
            guard let capture = configuration.3, let events = configuration.4 else {
                throw MobileRealtimeAudioError.missingRestartConfiguration
            }
            stopHoldingLifecycleLock(clearConfiguration: false)
            if recreateGraph {
                workQueue.sync {
                    engine = AVAudioEngine()
                    playerNode = AVAudioPlayerNode()
                }
            }
            try startHoldingLifecycleLock(
                captureSampleRate: configuration.0,
                playbackSampleRate: configuration.1,
                isMicrophoneMuted: configuration.2,
                onCapturedAudio: capture,
                onAudioEvent: events
            )
        }
    }

    /// The body of `stop()`. Callers hold `lifecycleLock`.
    private func stopHoldingLifecycleLock(clearConfiguration: Bool) {
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
            self.routeObserver = nil
        }
        for observer in sessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        sessionObservers.removeAll()
        workQueue.sync {
            // Closes the playback gate before the node is torn down, so a
            // buffer already queued behind this block is discarded instead of
            // being scheduled onto a detached node.
            isGraphRunning = false
            if inputTapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                inputTapInstalled = false
            }
            playerNode.stop()
            engine.stop()
            if engine.attachedNodes.contains(playerNode) {
                engine.detach(playerNode)
            }
            if clearConfiguration {
                onCapturedAudio = nil
                onAudioEvent = nil
            }
            captureConverter = nil
            pendingCapture = Data()
            playerStarted = false
            pendingPlaybackBuffers = 0
            playbackProgressCheckScheduled = false
            didReportPlaybackStall = false
            playbackGeneration &+= 1
            captureMutedUntil = 0
            playbackItemGeneration &+= 1
            completedItemFrames = 0
            lastInputLevelEmission = 0
        }
    }

    func setMicrophoneMuted(_ muted: Bool) {
        workQueue.async { [weak self] in
            guard let self else { return }
            isMicrophoneMuted = muted
            pendingCapture.removeAll(keepingCapacity: true)
            if muted {
                onAudioEvent?(.inputLevel(0))
            }
        }
    }

    private func installSessionObservers(_ audioSession: AVAudioSession) {
        let center = NotificationCenter.default
        // CarPlay can replace the active I/O route after the conversation has
        // already started without delivering an AVAudioSession interruption.
        // AVAudioEngine keeps reporting itself as running in that state, but
        // its installed input tap may stop receiving buffers. Rebuild the graph
        // whenever Core Audio reports that its configuration changed so the
        // next learner turn reaches the realtime transport.
        sessionObservers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.emit(.configurationChanged)
        })
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: audioSession,
            queue: nil
        ) { [weak self] notification in
            guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
            switch type {
            case .began:
                self?.emit(.interruptionBegan)
            case .ended:
                let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
                self?.emit(.interruptionEnded(shouldResume: shouldResume))
            @unknown default:
                break
            }
        })
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: audioSession,
            queue: nil
        ) { [weak self] _ in
            self?.emit(.mediaServicesWereReset)
        })
    }

    private func emit(_ event: MobileRealtimeAudioEvent) {
        workQueue.async { [weak self] in
            self?.onAudioEvent?(event)
        }
    }

    // MARK: - Playback

    /// Queues PCM16 24 kHz mono model audio for playback.
    func enqueuePlayback(_ pcm16: Data) {
        // Decoding every PCM sample to Float is proportional to reply length.
        // Server events are consumed by the main-actor controller, so doing
        // that conversion inline made long replies visibly stall the UI.
        workQueue.async { [weak self] in
            guard let self else { return }
            // Not a stall. The graph is down only while `restart()` rebuilds
            // it for a route change or after `stop()` ended the session. The
            // controller already owns both; reporting a stall here made every
            // AirPods or CarPlay route change that landed mid-sentence replace
            // a healthy provider socket. A real stall is a running graph that
            // makes no render progress, which the progress check below
            // detects on its own.
            guard isGraphRunning else { return }
            guard playbackGate.acceptsAudio,
                  let buffer = self.pcm16ToFloatBuffer(pcm16) else { return }
            let generation = playbackGeneration
            let itemGeneration = playbackItemGeneration
            let frameCount = AVAudioFramePosition(buffer.frameLength)
            let startsAudibleRun = pendingPlaybackBuffers == 0
            pendingPlaybackBuffers += 1
            playerNode.scheduleBuffer(
                buffer,
                completionCallbackType: .dataPlayedBack
            ) { [weak self] _ in
                self?.workQueue.async { [weak self] in
                    self?.playbackCompleted(
                        generation: generation,
                        itemGeneration: itemGeneration,
                        frameCount: frameCount
                    )
                }
            }
            if !playerStarted {
                // Keep one continuously armed player for the whole response.
                // Pausing whenever the WebSocket queue briefly drained left
                // the node silent on real devices even though later buffers
                // were accepted and the UI correctly reported "Speaking".
                playerStarted = true
                playerNode.play()
            }
            if startsAudibleRun {
                onAudioEvent?(.playbackStarted)
                schedulePlaybackProgressCheck(generation: generation)
            }
        }
    }

    /// Drops everything queued and reports what the listener actually heard —
    /// the barge-in path. The next enqueue re-arms. Nothing here blocks the
    /// caller on Core Audio: completed buffers deliberately undercount the
    /// buffer still rendering, which is the safe direction for truncation.
    func stopPlaybackAndReturnPlayedMilliseconds() async -> Int {
        await withCheckedContinuation { continuation in
            workQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: 0)
                    return
                }
                let milliseconds = Self.milliseconds(
                    forCompletedFrames: completedItemFrames,
                    sampleRate: configuredPlaybackSampleRate
                )
                playbackGeneration &+= 1
                playbackGate.interrupt()
                pendingPlaybackBuffers = 0
                playbackProgressCheckScheduled = false
                didReportPlaybackStall = false
                captureMutedUntil = 0
                playerStarted = false
                completedItemFrames = 0
                if isGraphRunning { playerNode.stop() }
                continuation.resume(returning: milliseconds)
            }
        }
    }

    /// Reopens playback only at the next provider response boundary. Merely
    /// receiving another output item is insufficient: it can still belong to
    /// the response that was just interrupted.
    func beginResponsePlayback() {
        workQueue.async { [weak self] in
            self?.playbackGate.beginResponse()
        }
    }

    /// Starts a fresh truncation clock for a new output item.
    func resetPlaybackClock() {
        workQueue.async { [weak self] in
            guard let self else { return }
            playbackItemGeneration &+= 1
            completedItemFrames = 0
        }
    }

    static func milliseconds(
        forCompletedFrames frames: AVAudioFramePosition,
        sampleRate: Double = MobileRealtimeAudioIO.playbackSampleRate
    ) -> Int {
        guard sampleRate > 0 else { return 0 }
        return Int(Double(max(0, frames)) / sampleRate * 1_000)
    }

    /// Half-duplex gate: true while a buffer is still rendering or its room-
    /// reverb tail is live. AVAudioPlayerNode's sample clock stops at the final
    /// frame, so it cannot by itself time this tail — that was the regression
    /// which left the mic muted forever after the first model reply.
    private func isRenderingPlayback() -> Bool {
        pendingPlaybackBuffers > 0 || ProcessInfo.processInfo.systemUptime < captureMutedUntil
    }

    private func playbackCompleted(
        generation: UInt,
        itemGeneration: UInt,
        frameCount: AVAudioFramePosition
    ) {
        guard generation == playbackGeneration, pendingPlaybackBuffers > 0 else { return }
        pendingPlaybackBuffers -= 1
        if itemGeneration == playbackItemGeneration {
            completedItemFrames += frameCount
        }
        if pendingPlaybackBuffers == 0 {
            captureMutedUntil = ProcessInfo.processInfo.systemUptime + Self.echoTailSeconds
            // A short WebSocket scheduling gap is not a new speaking turn.
            // Debounce the drain edge; a newly scheduled buffer cancels it by
            // making pendingPlaybackBuffers nonzero before this closure runs.
            workQueue.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self,
                      generation == playbackGeneration,
                      pendingPlaybackBuffers == 0 else { return }
                onAudioEvent?(.playbackDrained)
            }
        }
    }

    private func schedulePlaybackProgressCheck(generation: UInt) {
        guard !playbackProgressCheckScheduled else { return }
        playbackProgressCheckScheduled = true
        let completedFrames = completedItemFrames
        workQueue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            playbackProgressCheckScheduled = false
            guard generation == playbackGeneration,
                  isGraphRunning,
                  pendingPlaybackBuffers > 0 else { return }
            guard completedItemFrames > completedFrames else {
                reportPlaybackStallOnce()
                return
            }
            schedulePlaybackProgressCheck(generation: generation)
        }
    }

    private func reportPlaybackStallOnce() {
        guard !didReportPlaybackStall else { return }
        didReportPlaybackStall = true
        onAudioEvent?(.playbackStalled)
    }

    static func routeChangeRequiresGraphRebuild(
        _ reason: AVAudioSession.RouteChangeReason?
    ) -> Bool {
        // setCategory can publish a bookkeeping-only category change. Every
        // actual route transition may replace CarPlay's I/O unit while leaving
        // AVAudioEngine.isRunning true, so rebuild rather than trusting it.
        reason != .categoryChange
    }

    private static func requiresHalfDuplexCapture(_ session: AVAudioSession) -> Bool {
        let usesBuiltInSpeaker = session.currentRoute.outputs.contains {
            $0.portType == .builtInSpeaker
        }
        guard usesBuiltInSpeaker else { return false }
        if #available(iOS 18.2, *) {
            return !session.isEchoCancelledInputEnabled
        }
        return true
    }

    private func refreshEchoSuppression() {
        let muteDuringPlayback = Self.requiresHalfDuplexCapture(AVAudioSession.sharedInstance())
        workQueue.async { [weak self] in
            self?.mutesCaptureDuringPlayback = muteDuringPlayback
        }
    }

    // MARK: - Capture conversion (workQueue)

    private func convertAndEmit(_ buffer: AVAudioPCMBuffer) {
        guard let converter = converter(matching: buffer.format) else { return }
        // No echo canceller: drop the mic while the speaker talks, or the model
        // hears itself, barges in on itself, and the session never ends. The
        // partial chunk goes too — half of the model's own sentence must not be
        // prepended to the user's next turn.
        if isMicrophoneMuted || (mutesCaptureDuringPlayback && isRenderingPlayback()) {
            pendingCapture.removeAll(keepingCapacity: true)
            return
        }
        let ratio = apiFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: apiFormat, frameCapacity: capacity) else { return }

        var fed = false
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, converted.frameLength > 0,
              let channel = converted.int16ChannelData?[0] else { return }

        emitInputLevelIfNeeded(channel, sampleCount: Int(converted.frameLength))

        pendingCapture.append(Data(bytes: channel, count: Int(converted.frameLength) * MemoryLayout<Int16>.size))
        while pendingCapture.count >= captureChunkBytes {
            let chunk = pendingCapture.prefix(captureChunkBytes)
            pendingCapture.removeFirst(captureChunkBytes)
            onCapturedAudio?(Data(chunk))
        }
    }

    /// The converter for the format the tap is actually delivering.
    ///
    /// A route change — AirPods connecting mid-answer is the everyday one — can
    /// change the input node's format under a tap that stays installed. Feeding
    /// those buffers to a converter built for the old format returns an error
    /// per buffer, so the learner keeps talking to a session that has quietly
    /// stopped hearing them. Rebuilding costs one allocation on the rare frame
    /// where the format actually moved.
    private func converter(matching inputFormat: AVAudioFormat) -> AVAudioConverter? {
        if let converter = captureConverter, converter.inputFormat == inputFormat {
            return converter
        }
        guard let apiFormat = self.apiFormat,
              let rebuilt = AVAudioConverter(from: inputFormat, to: apiFormat) else {
            return nil
        }
        captureConverter = rebuilt
        return rebuilt
    }

    private func emitInputLevelIfNeeded(_ samples: UnsafePointer<Int16>, sampleCount: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        guard sampleCount > 0, now - lastInputLevelEmission >= 0.08 else { return }
        lastInputLevelEmission = now

        var squareSum: Double = 0
        for index in 0..<sampleCount {
            let normalized = Double(samples[index]) / Double(Int16.max)
            squareSum += normalized * normalized
        }
        let rootMeanSquare = Float(sqrt(squareSum / Double(sampleCount)))
        onAudioEvent?(.inputLevel(min(max(rootMeanSquare, 0), 1)))
    }

    static func copied(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        // `frameCapacity` must be positive: AVAudioPCMBuffer traps on zero, and
        // a tap can hand back an empty buffer around a route change.
        guard buffer.frameLength > 0,
              let copy = AVAudioPCMBuffer(
                pcmFormat: buffer.format,
                frameCapacity: buffer.frameLength
              ) else { return nil }
        copy.frameLength = buffer.frameLength

        // Typed channel pointers describe channels, not AudioBufferList
        // entries: an interleaved multi-channel buffer has one memory buffer,
        // while a noninterleaved one has several. Indexing per channel walks
        // off the end of the pointer array on interleaved input (USB, CarPlay,
        // some Bluetooth), and `mBytesPerFrame` spans every channel there, so
        // the length would be wrong too. Copy the actual buffer list instead.
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }
        for index in sourceBuffers.indices {
            let source = sourceBuffers[index]
            let byteCount = Int(source.mDataByteSize)
            guard byteCount <= Int(destinationBuffers[index].mDataByteSize),
                  let sourceData = source.mData,
                  let destinationData = destinationBuffers[index].mData else { return nil }
            memcpy(destinationData, sourceData, byteCount)
        }
        return copy
    }

    private func pcm16ToFloatBuffer(_ data: Data) -> AVAudioPCMBuffer? {
        let frameCount = data.count / MemoryLayout<Int16>.size
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(frameCount)),
              let channel = buffer.floatChannelData?[0] else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for index in 0..<frameCount {
                channel[index] = Float(Int16(littleEndian: samples[index])) / 32_768.0
            }
        }
        speechLoudness.process(mono: channel, frameCount: frameCount)
        return buffer
    }
}

enum MobileRealtimeAudioError: LocalizedError {
    case inputUnavailable
    case unsupportedInputFormat
    case missingRestartConfiguration

    var errorDescription: String? {
        switch self {
        case .inputUnavailable:
            return "The microphone is unavailable for voice."
        case .unsupportedInputFormat:
            return "The microphone's audio format is unavailable for voice."
        case .missingRestartConfiguration:
            return "Realtime voice could not restore its microphone configuration."
        }
    }
}

/// `MobileRealtimeAudioIO` for the shared voice controller. It holds the
/// realtime lease on the audio session, asks for the microphone, and restores
/// the graph itself after route changes (AirPods, CarPlay), interruptions and
/// media-service resets, reporting only what the conversation needs to know.
final class MobileRealtimeVoiceAudio: RealtimeVoiceAudio, @unchecked Sendable {
    private struct State {
        var isRunning = false
        var isRestoring = false
        var restoreAgain = false
        var restoreRecreatesGraph = false
        var onEvent: (@Sendable (RealtimeVoiceAudioEvent) -> Void)?
    }

    private let io = MobileRealtimeAudioIO()
    private let state = OSAllocatedUnfairLock(initialState: State())

    func start(
        microphoneMuted: Bool,
        onCapturedAudio: @escaping @Sendable (Data) -> Void,
        onEvent: @escaping @Sendable (RealtimeVoiceAudioEvent) -> Void
    ) async throws {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw MobileRealtimeVoiceAudioError.microphoneDenied
        }
        let arbiter = MobileAudioSessionArbiter.shared
        await arbiter.register(.realtimeVoice) { [weak self] in
            await self?.preempted()
        }
        try await arbiter.acquire(.realtimeVoice, for: .conversation)
        state.withLock {
            $0.onEvent = onEvent
            $0.isRunning = true
        }
        let io = self.io
        do {
            try await Task.detached(priority: .userInitiated) { [weak self] in
                try io.start(
                    captureSampleRate: RealtimeVoiceDefaults.sampleRate,
                    playbackSampleRate: RealtimeVoiceDefaults.sampleRate,
                    isMicrophoneMuted: microphoneMuted,
                    onCapturedAudio: onCapturedAudio,
                    onAudioEvent: { [weak self] event in self?.handle(event) }
                )
            }.value
        } catch {
            state.withLock { $0.isRunning = false }
            await arbiter.release(.realtimeVoice)
            throw error
        }
    }

    func stop() async {
        let wasRunning = state.withLock { state -> Bool in
            let was = state.isRunning
            state.isRunning = false
            state.onEvent = nil
            return was
        }
        guard wasRunning else { return }
        let io = self.io
        await Task.detached(priority: .userInitiated) { io.stop() }.value
        await MobileAudioSessionArbiter.shared.release(.realtimeVoice)
    }

    func setMicrophoneMuted(_ muted: Bool) { io.setMicrophoneMuted(muted) }
    func enqueuePlayback(_ pcm16: Data) { io.enqueuePlayback(pcm16) }
    func beginResponsePlayback() { io.beginResponsePlayback() }
    func resetPlaybackClock() { io.resetPlaybackClock() }
    func stopPlayback() async -> Int { await io.stopPlaybackAndReturnPlayedMilliseconds() }

    private func forward(_ event: RealtimeVoiceAudioEvent) {
        let onEvent = state.withLock { $0.isRunning ? $0.onEvent : nil }
        onEvent?(event)
    }

    private func handle(_ event: MobileRealtimeAudioEvent) {
        switch event {
        case .inputLevel(let level): forward(.inputLevel(level))
        case .playbackStarted: forward(.playbackStarted)
        case .playbackDrained: forward(.playbackDrained)
        case .interruptionBegan: forward(.interruptionBegan)
        // `shouldResume` is only the system's hint; a conversation the learner
        // started comes back when the audio does, and the restart decides.
        case .interruptionEnded: restore(recreateGraph: false, announcesResume: true)
        // A route change can leave the engine "running" with a tap that no
        // longer delivers buffers; a stall is a graph that renders nothing.
        // Both need a fresh graph.
        case .configurationChanged, .mediaServicesWereReset, .playbackStalled:
            restore(recreateGraph: true, announcesResume: false)
        }
    }

    /// Rebuilds the graph under the lease. A restore requested while one runs
    /// is folded into one more pass, so bursts of route changes rebuild once.
    private func restore(recreateGraph: Bool, announcesResume: Bool) {
        let begins = state.withLock { state -> Bool in
            guard state.isRunning else { return false }
            state.restoreRecreatesGraph = state.restoreRecreatesGraph || recreateGraph
            if state.isRestoring {
                state.restoreAgain = true
                return false
            }
            state.isRestoring = true
            return true
        }
        guard begins else { return }
        let io = self.io
        Task.detached(priority: .userInitiated) { [weak self] in
            var lastError: Error?
            while let self {
                let recreate = self.state.withLock { state -> Bool in
                    let value = state.restoreRecreatesGraph
                    state.restoreRecreatesGraph = false
                    state.restoreAgain = false
                    return value
                }
                lastError = nil
                // One quick retry: a route switch can still be settling.
                for attempt in 0..<2 {
                    do {
                        if attempt > 0 { try? await Task.sleep(for: .milliseconds(600)) }
                        guard self.state.withLock({ $0.isRunning }) else { return }
                        try await MobileAudioSessionArbiter.shared.acquire(.realtimeVoice, for: .conversation)
                        try io.restart(recreateGraph: recreate || attempt > 0)
                        lastError = nil
                        break
                    } catch {
                        lastError = error
                    }
                }
                let again = self.state.withLock { state -> Bool in
                    if state.restoreAgain, state.isRunning { return true }
                    state.isRestoring = false
                    return false
                }
                if !again { break }
            }
            guard let self else { return }
            if let lastError {
                self.forward(.failed("The audio could not come back after a change of speaker or microphone: \(lastError.localizedDescription)"))
            } else if announcesResume {
                self.forward(.interruptionEnded)
            }
        }
    }

    /// Another part of the app took the audio session (narration, the
    /// turn-by-turn voice, dictation).
    private func preempted() async {
        let onEvent = state.withLock { state -> (@Sendable (RealtimeVoiceAudioEvent) -> Void)? in
            guard state.isRunning else { return nil }
            state.isRunning = false
            let handler = state.onEvent
            state.onEvent = nil
            return handler
        }
        guard let onEvent else { return }
        let io = self.io
        await Task.detached(priority: .userInitiated) { io.stop() }.value
        onEvent(.failed("Something else started playing, so voice stopped."))
    }
}

enum MobileRealtimeVoiceAudioError: LocalizedError {
    case microphoneDenied

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access is off for ForeverLM. Turn it on in Settings › Privacy & Security › Microphone."
        }
    }
}
