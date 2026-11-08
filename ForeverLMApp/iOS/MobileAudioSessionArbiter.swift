import AVFoundation
import Foundation

// The single owner of AVAudioSession on iOS. Nothing else in the app may call
// setCategory/setActive.
//
// AVAudioSession.sharedInstance() is one process-wide object, so a second
// "owner" is not a second session — it is a mutation of the first. Reconfiguring
// while AVAudioEngine is running restarts the route: the installed input tap
// survives but stops delivering buffers, so SFSpeechAudioBufferRecognitionRequest
// sits silent forever and the Voice tab looks like it is listening while being
// deaf. Worse, two live mic owners feed the synthesizer's own output back into
// recognition and the app starts talking to itself.
//
// So audio consumers take a lease instead of configuring the session directly.
// Leases preempt rather than queue: half-duplex is the invariant, and the
// outgoing holder's teardown runs to completion before the session is
// reconfigured.
actor MobileAudioSessionArbiter {
    static let shared = MobileAudioSessionArbiter()

    enum Holder: String, Sendable {
        case voiceTab
        // The reading surface's mic and its spoken replies are two holders, not
        // one: preemption is per holder, so a shared case would let the chat's
        // reply keep talking into a mic the arbiter just armed elsewhere — and
        // would let either consumer drop the lease the other depends on.
        case readingDictation
        case readingSpeech
        // Voice mode's WebRTC call on OpenAI Realtime
        // (`MobileRealtimeVoicePlatformAudio`): the one full-duplex holder. It owns both directions at once, so the
        // half-duplex invariant applies between holders, not within this one.
        case realtimeVoice
    }

    // Playback is exclusive so starting ForeverLM narration pauses any podcast
    // or music already playing on the device. Recording keeps the legacy mixed
    // session shape so its existing handoff behavior remains unchanged.
    enum Intent: Sendable {
        case playback
        case record
        // Voice mode's shape: voice chat, whose voice-processing I/O cancels
        // the speaker's echo on every route.
        case conversation
    }

    private var holder: Holder?
    private var preemptHandlers: [Holder: @Sendable () async -> Void] = [:]

    /// Registers how `holder` tears itself down when another holder takes the
    /// session. Call once, at the owning object's setup.
    func register(_ holder: Holder, onPreempt: @escaping @Sendable () async -> Void) {
        preemptHandlers[holder] = onPreempt
    }

    /// Grants the session to `holder`, first driving the current holder's
    /// teardown if it is somebody else.
    func acquire(_ holder: Holder, for intent: Intent) async throws {
        let outgoing = self.holder
        // Claim the lease before awaiting teardown so a concurrent acquire by the
        // same incoming holder cannot preempt the outgoing one a second time.
        self.holder = holder
        if let outgoing, outgoing != holder {
            await preemptHandlers[outgoing]?()
        }
        try await configure(intent)
    }

    /// Releases the lease. A stale release from a holder that has already been
    /// preempted is a no-op.
    func release(_ holder: Holder) {
        guard self.holder == holder else { return }
        self.holder = nil
    }

    /// Whether `holder` still owns the session. Callers re-arm a microphone only
    /// when this is true — the arbiter, not the caller's own flags, is the
    /// authority on who may listen.
    func holds(_ holder: Holder) -> Bool {
        self.holder == holder
    }

    private func configure(_ intent: Intent) async throws {
        // setCategory/setActive block; on the main actor with an active session
        // they trigger the AVAudioSession UI-unresponsiveness warning.
        try await Task.detached(priority: .userInitiated) {
            let session = AVAudioSession.sharedInstance()
            switch intent {
            case .playback:
                // Narration is output-only. Declaring it as playAndRecord puts
                // AirPods onto their input-capable call route, where a stem press
                // can be treated as a microphone gesture instead of a media
                // play/pause command. The playback category uses the A2DP media
                // route automatically and makes this session eligible for the
                // Now Playing remote commands registered by the player.
                //
                // Deliberately omit .mixWithOthers: activating this session must
                // interrupt other apps' podcasts and music before narration starts.
                try session.setCategory(
                    .playback,
                    mode: .spokenAudio,
                    options: []
                )
            case .record:
                // Recording retains mixing so re-arming an app-owned microphone
                // does not introduce a second behavioral change in this handoff.
                try session.setCategory(
                    .playAndRecord,
                    mode: .spokenAudio,
                    options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker, .mixWithOthers]
                )
            case .conversation:
                // Voice mode's WebRTC call (`RealtimeVoiceSession`), set up
                // exactly as WebRTC sets it up itself: voice chat mode, whose
                // voice-processing I/O cancels the speaker's echo, so the model
                // never hears itself and cuts its own reply short. The speaker
                // when nothing is connected; AirPods and CarPlay take the call
                // route. No .mixWithOthers: a conversation needs the un-ducked
                // route.
                try session.setCategory(
                    .playAndRecord,
                    mode: .voiceChat,
                    options: [.allowBluetoothHFP, .defaultToSpeaker]
                )
            }
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        }.value
    }
}
