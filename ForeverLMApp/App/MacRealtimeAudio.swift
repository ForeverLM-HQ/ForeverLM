@preconcurrency import AVFoundation
import Foundation
import os

#if os(macOS)
private let macRealtimeAudioLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM",
    category: "RealtimeAudio"
)

enum MacRealtimeAudioEvent: Sendable {
    case configurationChanged
    /// Normalized RMS (0...1) from the microphone after format conversion.
    /// Emitted off-main at a throttled cadence so the UI can show whether the
    /// active input is actually producing usable audio, rather than inferring
    /// "Listening" from the socket state alone.
    case inputLevel(Float)
    /// The first buffer of a run of reply audio was scheduled.
    case playbackStarted
    /// The last scheduled buffer finished playing (debounced, so a short gap in
    /// the stream is not a new turn).
    case playbackDrained
}

enum MacRealtimeCaptureCheck: Sendable, Equatable {
    case startupFrames
    case postPlaybackFrames
}

/// Full-duplex macOS audio for voice mode (`RealtimeVoiceController`, OpenAI
/// Realtime). Ported from the first voice mode (removed 2026-10-01), where
/// its device-switch and split-route handling was worked out. The engine's
/// voice-processing I/O supplies acoustic echo cancellation when the active
/// devices support it. macOS cannot initialize voice processing for some split
/// input/output routes, so those routes use a half-duplex capture gate instead:
/// microphone frames are dropped only while model audio (and its short room-
/// echo tail) is audible. All format conversion and PCM decoding stays on a
/// private queue so Core Audio and the main actor never perform proportional
/// work.
final class MacRealtimeAudioIO: @unchecked Sendable {
    static let playbackSampleRate = 24_000.0
    private static let echoTailSeconds: TimeInterval = 0.2

    private var engine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    private let workQueue = DispatchQueue(label: "com.foreverlm.mac-realtime-audio")
    /// AVAudioEngine teardown synchronizes with Core Audio workers that run at
    /// Default QoS. Running lifecycle calls on a matching serial queue keeps a
    /// user-initiated caller suspended instead of blocking it on those workers.
    private let lifecycleQueue = DispatchQueue(
        label: "com.foreverlm.mac-realtime-audio-lifecycle",
        qos: .default
    )
    private let lifecycleLock = NSRecursiveLock()
    private var configurationObserver: NSObjectProtocol?

    private var playbackFormat = AVAudioFormat(
        standardFormatWithSampleRate: MacRealtimeAudioIO.playbackSampleRate,
        channels: 1
    )!

    // workQueue-confined state.
    private var apiFormat: AVAudioFormat!
    private var captureChunkBytes = 0
    private var captureConverter: AVAudioConverter?
    private var pendingCapture = Data()
    private var onCapturedAudio: (@Sendable (Data) -> Void)?
    private var onAudioEvent: (@Sendable (MacRealtimeAudioEvent) -> Void)?
    private var configuredCaptureSampleRate = MacRealtimeAudioIO.playbackSampleRate
    private var configuredPlaybackSampleRate = MacRealtimeAudioIO.playbackSampleRate
    private var configuredPrefersVoiceProcessing = true
    private var inputTapInstalled = false
    private var activeVoiceProcessingEnabled = false
    private var emittedCaptureStarted = false
    /// Silence is still valid capture. Recovery is warranted only when the tap
    /// stops delivering frames, never merely because the room is quiet.
    private var receivedCaptureFramesSincePlayback = false
    private var captureRecoveryGeneration: UInt = 0
    /// True only between a successful `engine.start()` and the next `stop()`.
    /// `AVAudioPlayerNode` raises an uncatchable exception when a buffer is
    /// scheduled on it — or when it is started — while it is detached or its
    /// engine is not running, so every playback call is gated on this.
    private var isGraphRunning = false
    /// Playback progress is derived only from completed buffers. Asking
    /// `AVAudioNode.lastRenderTime` for the live clock can wait for an I/O cycle
    /// while Core Audio is reconfiguring the engine, deadlocking voice mode.
    private var playbackItemGeneration: UInt = 0
    private var completedItemFrames: AVAudioFramePosition = 0
    private var playerStarted = false
    private var pendingPlaybackBuffers = 0
    private var playbackGeneration: UInt = 0
    /// Blocks late deltas from an interrupted response until the transport
    /// announces the next response. Provider cancellation is asynchronous, so
    /// stopping AVAudioPlayerNode alone is not a durable silence boundary.
    private var playbackGate = RealtimePlaybackGate()
    private var captureMutedUntil: TimeInterval = 0
    private var mutesCaptureDuringPlayback = false
    private var isMicrophoneMuted = false
    private var lastInputLevelEmission: TimeInterval = 0

    func start(
        captureSampleRate: Double = MacRealtimeAudioIO.playbackSampleRate,
        playbackSampleRate: Double = MacRealtimeAudioIO.playbackSampleRate,
        onCapturedAudio: @escaping @Sendable (Data) -> Void,
        onAudioEvent: @escaping @Sendable (MacRealtimeAudioEvent) -> Void = { _ in }
    ) async throws {
        try await performLifecycle {
            try self.startSynchronously(
                captureSampleRate: captureSampleRate,
                playbackSampleRate: playbackSampleRate,
                prefersVoiceProcessing: true,
                onCapturedAudio: onCapturedAudio,
                onAudioEvent: onAudioEvent
            )
        }
    }

    private func startSynchronously(
        captureSampleRate: Double,
        playbackSampleRate: Double,
        prefersVoiceProcessing: Bool,
        onCapturedAudio: @escaping @Sendable (Data) -> Void,
        onAudioEvent: @escaping @Sendable (MacRealtimeAudioEvent) -> Void
    ) throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        let apiFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: captureSampleRate,
            channels: 1,
            interleaved: true
        )!
        let playbackFormat = AVAudioFormat(
            standardFormatWithSampleRate: playbackSampleRate,
            channels: 1
        )!

        workQueue.sync {
            self.apiFormat = apiFormat
            captureChunkBytes = Int(captureSampleRate * 0.1) * MemoryLayout<Int16>.size
            self.onCapturedAudio = onCapturedAudio
            self.onAudioEvent = onAudioEvent
            configuredCaptureSampleRate = captureSampleRate
            configuredPlaybackSampleRate = playbackSampleRate
            configuredPrefersVoiceProcessing = prefersVoiceProcessing
            self.playbackFormat = playbackFormat
            pendingCapture = Data()
            playbackItemGeneration &+= 1
            completedItemFrames = 0
            playerStarted = false
            pendingPlaybackBuffers = 0
            playbackGate = RealtimePlaybackGate()
            captureMutedUntil = 0
            mutesCaptureDuringPlayback = false
            lastInputLevelEmission = 0
            activeVoiceProcessingEnabled = false
            emittedCaptureStarted = false
            receivedCaptureFramesSincePlayback = false
            captureRecoveryGeneration &+= 1
        }

        try startGraphRetryingTransientFailures(prefersVoiceProcessing: prefersVoiceProcessing)
    }

    /// Delays between graph-start attempts that failed transiently. Core Audio
    /// builds a default-device aggregate for the I/O unit, and when the system's
    /// default input or output device changes while that happens — AirPods
    /// bring their microphone online about two seconds after they take the
    /// output — the aggregate fails validation ("racing against config change")
    /// and both the voice-processing and normal I/O units report
    /// kAudioUnitErr_FailedInitialization (-10875). Waiting out that window
    /// turns a dead session into a slightly longer "Connecting…".
    static let transientStartRetryDelays: [TimeInterval] = [0.75, 1.5, 2.0]

    /// The delay before retrying after `error` ended attempt number `attempt`
    /// (zero-based), or nil when the failure is not transient or the retry
    /// budget is spent.
    static func retryDelay(afterFailedAttempt attempt: Int, error: Error) -> TimeInterval? {
        guard isTransientInitializationFailure(error),
              transientStartRetryDelays.indices.contains(attempt) else { return nil }
        return transientStartRetryDelays[attempt]
    }

    /// True for kAudioUnitErr_FailedInitialization (-10875) from Core Audio,
    /// including when it is the fallback failure inside `audioEngineUnavailable`.
    /// The voice-processing attempt's own error is not consulted: it fails for
    /// stable split routes too, and only the fallback says whether plain I/O
    /// could open the devices at all.
    static func isTransientInitializationFailure(_ error: Error) -> Bool {
        if let audioError = error as? MacRealtimeAudioError {
            guard case .audioEngineUnavailable(_, let fallback) = audioError else { return false }
            return isTransientInitializationFailure(fallback)
        }
        let nsError = error as NSError
        guard nsError.code == Int(kAudioUnitErr_FailedInitialization) else { return false }
        return nsError.domain == "com.apple.coreaudio.avfaudio"
            || nsError.domain == NSOSStatusErrorDomain
    }

    private func startGraphRetryingTransientFailures(prefersVoiceProcessing: Bool) throws {
        var attempt = 0
        while true {
            do {
                try startGraph(prefersVoiceProcessing: prefersVoiceProcessing)
                if attempt > 0 {
                    macRealtimeAudioLogger.notice(
                        "Realtime audio started after \(attempt, privacy: .public) retried attempt(s) once the default audio devices settled."
                    )
                }
                return
            } catch {
                guard let delay = Self.retryDelay(afterFailedAttempt: attempt, error: error) else {
                    throw error
                }
                attempt += 1
                macRealtimeAudioLogger.notice(
                    "Realtime audio graph failed to initialize while the default audio devices were changing; retrying in \(delay, privacy: .public) s (attempt \(attempt, privacy: .public)). Error: \(error.localizedDescription, privacy: .public)"
                )
                stop(clearConfiguration: false)
                recreateGraph()
                // Runs on the lifecycle queue, so the suspended caller and any
                // queued stop() wait here rather than blocking a thread of theirs.
                Thread.sleep(forTimeInterval: delay)
            }
        }
    }

    private func startGraph(prefersVoiceProcessing: Bool) throws {
        guard prefersVoiceProcessing else {
            try configureAndStartGraph(voiceProcessingEnabled: false)
            macRealtimeAudioLogger.notice("Using normal I/O for reliable realtime microphone capture.")
            return
        }

        do {
            try configureAndStartGraph(voiceProcessingEnabled: true)
        } catch let voiceProcessingError {
            // Voice processing uses one aggregate I/O unit. macOS currently
            // fails that unit with kAudioUnitErr_FailedInitialization (-10875)
            // for valid split routes such as AirPods input + Mac speakers. A
            // fresh normal-I/O graph avoids the aggregate-device requirement;
            // the capture gate below still prevents acoustic self-interruption.
            stop(clearConfiguration: false)
            recreateGraph()
            do {
                try configureAndStartGraph(voiceProcessingEnabled: false)
                workQueue.sync { configuredPrefersVoiceProcessing = false }
                macRealtimeAudioLogger.notice(
                    "Voice processing could not start; using half-duplex echo suppression. Error: \(voiceProcessingError.localizedDescription, privacy: .public)"
                )
            } catch let fallbackError {
                throw MacRealtimeAudioError.audioEngineUnavailable(
                    voiceProcessing: voiceProcessingError,
                    fallback: fallbackError
                )
            }
        }
    }

    private func configureAndStartGraph(voiceProcessingEnabled: Bool) throws {
        let input = engine.inputNode
        if voiceProcessingEnabled {
            try input.setVoiceProcessingEnabled(true)
        }
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw MacRealtimeAudioError.inputUnavailable
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: apiFormat) else {
            throw MacRealtimeAudioError.unsupportedInputFormat
        }
        workQueue.sync { captureConverter = converter }

        input.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let copy = Self.copied(buffer) else { return }
            workQueue.async { self.convertAndEmit(copy) }
        }
        workQueue.sync { inputTapInstalled = true }

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.emit(.configurationChanged)
        }

        workQueue.sync {
            activeVoiceProcessingEnabled = voiceProcessingEnabled
            mutesCaptureDuringPlayback = !voiceProcessingEnabled
        }
        engine.prepare()
        try engine.start()
        // Only now is the player attached to a running engine. Buffers that
        // arrived while the graph was being rebuilt were dropped rather than
        // scheduled onto a node that would have trapped.
        let recoveryGeneration: UInt? = workQueue.sync {
            isGraphRunning = true
            guard voiceProcessingEnabled else { return nil }
            captureRecoveryGeneration &+= 1
            return captureRecoveryGeneration
        }
        if let recoveryGeneration {
            scheduleCaptureRecovery(
                after: 2,
                generation: recoveryGeneration,
                check: .startupFrames
            )
        }
    }

    func stop() async {
        await performLifecycle {
            self.lifecycleLock.lock()
            defer { self.lifecycleLock.unlock() }
            self.stop(clearConfiguration: true)
        }
    }

    func restart() async throws {
        try await performLifecycle {
            try self.restart(prefersVoiceProcessing: nil)
        }
    }

    /// Voice-processing I/O sometimes starts without throwing but never
    /// produces usable input. Rebuild with the normal I/O unit while preserving
    /// the capture callback and provider-native sample rates.
    func restartWithoutVoiceProcessing() throws {
        try restart(prefersVoiceProcessing: false)
    }

    private func restart(prefersVoiceProcessing: Bool?) throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        let configuration = workQueue.sync {
            (
                configuredCaptureSampleRate,
                configuredPlaybackSampleRate,
                onCapturedAudio,
                onAudioEvent,
                prefersVoiceProcessing ?? configuredPrefersVoiceProcessing
            )
        }
        guard let capture = configuration.2, let events = configuration.3 else {
            throw MacRealtimeAudioError.missingRestartConfiguration
        }
        stop(clearConfiguration: false)
        recreateGraph()
        try startSynchronously(
            captureSampleRate: configuration.0,
            playbackSampleRate: configuration.1,
            prefersVoiceProcessing: configuration.4,
            onCapturedAudio: capture,
            onAudioEvent: events
        )
    }

    private func stop(clearConfiguration: Bool) {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
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
                isMicrophoneMuted = false
            }
            captureConverter = nil
            pendingCapture = Data()
            playerStarted = false
            pendingPlaybackBuffers = 0
            playbackGeneration &+= 1
            captureMutedUntil = 0
            mutesCaptureDuringPlayback = false
            activeVoiceProcessingEnabled = false
            emittedCaptureStarted = false
            receivedCaptureFramesSincePlayback = false
            captureRecoveryGeneration &+= 1
            playbackItemGeneration &+= 1
            completedItemFrames = 0
        }
    }

    private func recreateGraph() {
        workQueue.sync {
            engine = AVAudioEngine()
            playerNode = AVAudioPlayerNode()
        }
    }

    static func shouldRecoverCapture(
        voiceProcessingEnabled: Bool,
        receivedFrames: Bool,
        check: MacRealtimeCaptureCheck
    ) -> Bool {
        guard voiceProcessingEnabled else { return false }
        switch check {
        case .startupFrames:
            return !receivedFrames
        case .postPlaybackFrames:
            return !receivedFrames
        }
    }

    private func scheduleCaptureRecovery(
        after delay: TimeInterval,
        generation: UInt,
        check: MacRealtimeCaptureCheck
    ) {
        lifecycleQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.recoverCaptureIfNeeded(generation: generation, check: check)
        }
    }

    /// This variant documents that its caller already runs on `workQueue`; the
    /// scheduling operation itself never synchronously re-enters that queue.
    private func scheduleCaptureRecoveryFromWorkQueue(
        after delay: TimeInterval,
        generation: UInt,
        check: MacRealtimeCaptureCheck
    ) {
        scheduleCaptureRecovery(after: delay, generation: generation, check: check)
    }

    private func recoverCaptureIfNeeded(
        generation: UInt,
        check: MacRealtimeCaptureCheck
    ) {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        let shouldRecover = workQueue.sync {
            generation == captureRecoveryGeneration
                && isGraphRunning
                && !isMicrophoneMuted
                && Self.shouldRecoverCapture(
                    voiceProcessingEnabled: activeVoiceProcessingEnabled,
                    receivedFrames: check == .startupFrames
                        ? emittedCaptureStarted
                        : receivedCaptureFramesSincePlayback,
                    check: check
                )
        }
        guard shouldRecover else { return }

        do {
            try restartWithoutVoiceProcessing()
            macRealtimeAudioLogger.notice(
                "Voice-processing input was unresponsive; recovered with normal I/O."
            )
        } catch {
            macRealtimeAudioLogger.error(
                "Normal-I/O microphone recovery failed: \(error.localizedDescription, privacy: .public)"
            )
            // Let the controller's existing route-recovery path retry and, if
            // that also fails, surface its terminal audio error to the learner.
            emit(.configurationChanged)
        }
    }

    private func emit(_ event: MacRealtimeAudioEvent) {
        workQueue.async { [weak self] in self?.onAudioEvent?(event) }
    }

    private func performLifecycle(
        _ operation: @escaping @Sendable () -> Void
    ) async {
        await withCheckedContinuation { continuation in
            lifecycleQueue.async {
                operation()
                continuation.resume()
            }
        }
    }

    private func performLifecycle(
        _ operation: @escaping @Sendable () throws -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lifecycleQueue.async {
                do {
                    try operation()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func setMicrophoneMuted(_ muted: Bool) {
        // The macOS AirPods mute handler must finish muting the uplink before
        // it reports success to AVAudioApplication. This block only changes
        // queue-confined flags and clears at most one 100 ms capture chunk, so
        // it is safe to complete synchronously without touching Core Audio.
        workQueue.sync {
            isMicrophoneMuted = muted
            // Never forward the leading or trailing half of an utterance
            // across a mute boundary.
            pendingCapture.removeAll(keepingCapacity: true)
            if muted { onAudioEvent?(.inputLevel(0)) }
            if !muted, activeVoiceProcessingEnabled, !emittedCaptureStarted {
                captureRecoveryGeneration &+= 1
                scheduleCaptureRecoveryFromWorkQueue(
                    after: 2,
                    generation: captureRecoveryGeneration,
                    check: .startupFrames
                )
            }
        }
    }

    // MARK: Playback

    func enqueuePlayback(_ pcm16: Data) {
        workQueue.async { [weak self] in
            guard let self,
                  isGraphRunning,
                  playbackGate.acceptsAudio,
                  let buffer = pcm16ToFloatBuffer(pcm16) else { return }
            let generation = playbackGeneration
            let itemGeneration = playbackItemGeneration
            let frameCount = AVAudioFramePosition(buffer.frameLength)
            let startsAudibleRun = pendingPlaybackBuffers == 0
            pendingPlaybackBuffers += 1
            captureMutedUntil = 0
            if startsAudibleRun { onAudioEvent?(.playbackStarted) }
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
                playerStarted = true
                playerNode.play()
            }
        }
    }

    /// Stops playback without blocking the caller on Core Audio. Completed
    /// buffers deliberately undercount the currently rendering buffer, which
    /// is the safe direction for provider truncation during barge-in.
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
                captureMutedUntil = 0
                playerStarted = false
                completedItemFrames = 0
                if isGraphRunning { playerNode.stop() }
                continuation.resume(returning: milliseconds)
            }
        }
    }

    func beginResponsePlayback() {
        workQueue.async { [weak self] in
            self?.playbackGate.beginResponse()
        }
    }

    func resetPlaybackClock() {
        workQueue.async { [weak self] in
            guard let self else { return }
            playbackItemGeneration &+= 1
            completedItemFrames = 0
        }
    }

    static func milliseconds(
        forCompletedFrames frames: AVAudioFramePosition,
        sampleRate: Double = playbackSampleRate
    ) -> Int {
        Int(Double(max(0, frames)) / sampleRate * 1_000)
    }

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
            workQueue.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self,
                      generation == playbackGeneration,
                      pendingPlaybackBuffers == 0 else { return }
                onAudioEvent?(.playbackDrained)
            }
            if activeVoiceProcessingEnabled {
                receivedCaptureFramesSincePlayback = false
                captureRecoveryGeneration &+= 1
                scheduleCaptureRecoveryFromWorkQueue(
                    after: 8,
                    generation: captureRecoveryGeneration,
                    check: .postPlaybackFrames
                )
            }
        }
    }

    // MARK: Capture conversion

    private func convertAndEmit(_ buffer: AVAudioPCMBuffer) {
        guard let converter = captureConverter else { return }
        if isMicrophoneMuted || (mutesCaptureDuringPlayback && isRenderingPlayback()) {
            pendingCapture.removeAll(keepingCapacity: true)
            return
        }
        let ratio = apiFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: apiFormat, frameCapacity: capacity) else { return }

        var fed = false
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard conversionError == nil,
              converted.frameLength > 0,
              let channel = converted.int16ChannelData?[0] else { return }

        receivedCaptureFramesSincePlayback = true
        if !emittedCaptureStarted {
            emittedCaptureStarted = true
        }

        emitInputLevelIfNeeded(channel, sampleCount: Int(converted.frameLength))

        pendingCapture.append(
            Data(bytes: channel, count: Int(converted.frameLength) * MemoryLayout<Int16>.size)
        )
        while pendingCapture.count >= captureChunkBytes {
            let chunk = pendingCapture.prefix(captureChunkBytes)
            pendingCapture.removeFirst(captureChunkBytes)
            onCapturedAudio?(Data(chunk))
        }
    }

    private func emitInputLevelIfNeeded(_ samples: UnsafePointer<Int16>, sampleCount: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        guard sampleCount > 0, now - lastInputLevelEmission >= 0.08 else { return }
        lastInputLevelEmission = now

        var sumOfSquares = 0.0
        for index in 0..<sampleCount {
            let normalized = Double(samples[index]) / Double(Int16.max)
            sumOfSquares += normalized * normalized
        }
        let rms = Float(sqrt(sumOfSquares / Double(sampleCount)))
        let level = min(max(rms, 0), 1)
        onAudioEvent?(.inputLevel(level))
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

        // Core Audio exposes the built-in Mac microphone as interleaved
        // multi-channel PCM on the normal-I/O fallback used when voice
        // processing cannot start. Typed channel pointers describe channels,
        // not AudioBufferList entries: an interleaved three-channel buffer has
        // one memory buffer, while a noninterleaved buffer has three. Copy the
        // actual buffer list so both layouts remain valid.
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
              let buffer = AVAudioPCMBuffer(
                pcmFormat: playbackFormat,
                frameCapacity: AVAudioFrameCount(frameCount)
              ),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for index in 0..<frameCount {
                channel[index] = Float(Int16(littleEndian: samples[index])) / 32_768
            }
        }
        return buffer
    }
}

enum MacRealtimeAudioError: LocalizedError {
    case inputUnavailable
    case unsupportedInputFormat
    case missingRestartConfiguration
    case audioEngineUnavailable(voiceProcessing: Error, fallback: Error)

    var errorDescription: String? {
        switch self {
        case .inputUnavailable:
            return "The microphone is unavailable for voice mode."
        case .unsupportedInputFormat:
            return "The microphone's audio format is unavailable for voice mode."
        case .missingRestartConfiguration:
            return "Voice mode could not restore its microphone configuration."
        case .audioEngineUnavailable(let voiceProcessing, let fallback):
            if MacRealtimeAudioIO.isTransientInitializationFailure(fallback) {
                return "The Mac’s audio devices could not start voice mode because the default "
                    + "input or output device kept changing, as it does while AirPods connect. "
                    + "Try again in a moment."
            }
            return "The Mac’s audio devices could not start voice mode. "
                + "Voice processing: \(voiceProcessing.localizedDescription) "
                + "Fallback: \(fallback.localizedDescription)"
        }
    }
}
/// `MacRealtimeAudioIO` for the shared voice controller: it asks for the
/// microphone, starts the graph, and rebuilds it when the Mac's audio devices
/// change (AirPods connecting, a display's speakers, a USB microphone),
/// reporting only what the conversation needs to know.
final class MacRealtimeVoiceAudio: RealtimeVoiceAudio, @unchecked Sendable {
    private struct State {
        var isRunning = false
        var isRestoring = false
        var restoreAgain = false
        var onEvent: (@Sendable (RealtimeVoiceAudioEvent) -> Void)?
    }

    private let io = MacRealtimeAudioIO()
    private let state = OSAllocatedUnfairLock(initialState: State())

    func start(
        microphoneMuted: Bool,
        onCapturedAudio: @escaping @Sendable (Data) -> Void,
        onEvent: @escaping @Sendable (RealtimeVoiceAudioEvent) -> Void
    ) async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw MacRealtimeVoiceAudioError.microphoneDenied
        }
        state.withLock {
            $0.onEvent = onEvent
            $0.isRunning = true
        }
        do {
            try await io.start(
                captureSampleRate: RealtimeVoiceDefaults.sampleRate,
                playbackSampleRate: RealtimeVoiceDefaults.sampleRate,
                onCapturedAudio: onCapturedAudio,
                onAudioEvent: { [weak self] event in self?.handle(event) }
            )
            if microphoneMuted { io.setMicrophoneMuted(true) }
        } catch {
            state.withLock { $0.isRunning = false }
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
        await io.stop()
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

    private func handle(_ event: MacRealtimeAudioEvent) {
        switch event {
        case .inputLevel(let level): forward(.inputLevel(level))
        case .playbackStarted: forward(.playbackStarted)
        case .playbackDrained: forward(.playbackDrained)
        case .configurationChanged: restore()
        }
    }

    /// Rebuilds the graph after a device change. Changes that arrive while one
    /// rebuild runs fold into one more pass; the graph's own start already
    /// waits out the seconds a default device takes to settle.
    private func restore() {
        let begins = state.withLock { state -> Bool in
            guard state.isRunning else { return false }
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
                self.state.withLock { $0.restoreAgain = false }
                lastError = nil
                guard self.state.withLock({ $0.isRunning }) else { return }
                do {
                    try await io.restart()
                } catch {
                    lastError = error
                }
                let again = self.state.withLock { state -> Bool in
                    if state.restoreAgain, state.isRunning { return true }
                    state.isRestoring = false
                    return false
                }
                if !again { break }
            }
            guard let self, let lastError else { return }
            self.forward(.failed("The audio could not come back after a change of speaker or microphone: \(lastError.localizedDescription)"))
        }
    }
}

enum MacRealtimeVoiceAudioError: LocalizedError {
    case microphoneDenied

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access is off for ForeverLM. Turn it on in System Settings › Privacy & Security › Microphone."
        }
    }
}
#endif
