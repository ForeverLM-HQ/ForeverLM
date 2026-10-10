import Foundation
import Testing
@testable import ForeverLM

/// The voice surface's account of what the tutor is doing. The controller's
/// `statusText` can still read "Listening" from the turn before, so the
/// presentation leans on the controller's own "a reply is owed" fact as well.
@Suite("Voice session presentation state")
@MainActor
struct VoiceSessionPresentationStateTests {
    private func state(
        phase: VoiceSessionPhase = .live,
        status: String,
        muted: Bool = false,
        working: Bool
    ) -> VoiceSessionPresentationState {
        VoiceSessionPresentationState(
            phase: phase,
            statusText: status,
            headerTitle: "Voice",
            headerSystemImage: "waveform",
            contextItems: [],
            isMicrophoneMuted: muted,
            microphoneLevel: VoiceMicrophoneLevel(),
            terminalErrorMessage: nil,
            inlineErrorMessage: nil,
            isTutorWorking: working
        )
    }

    @Test("A stale Listening while a reply is owed reads and draws as Thinking")
    func staleListeningWhileWorking() {
        let live = state(status: "Listening", working: true)
        #expect(live.displayedStatus == "Thinking")
        #expect(live.voiceActivity == .thinking)

        let unset = state(status: "", working: true)
        #expect(unset.displayedStatus == "Thinking")
        #expect(unset.voiceActivity == .thinking)
    }

    @Test("A reading status keeps its label but drives the thinking mark")
    func readingStatusDrivesThinkingMark() {
        let reading = state(status: "Reading 3 sources…", working: true)
        #expect(reading.displayedStatus == "Reading 3 sources…")
        #expect(reading.voiceActivity == .thinking)

        let opening = state(status: "Opening today's review…", working: true)
        #expect(opening.displayedStatus == "Opening today's review…")
        #expect(opening.voiceActivity == .thinking)
    }

    @Test("Before the first turn the mark connects")
    func connectingBeforeTheFirstTurn() {
        let starting = state(phase: .connecting, status: "", working: false)
        #expect(starting.displayedStatus == "Getting ready…")
        #expect(starting.voiceActivity == .connecting)
    }

    @Test("Speaking outranks the working flag")
    func speakingWins() {
        let speaking = state(status: "Speaking", working: true)
        #expect(speaking.displayedStatus == "Speaking")
        #expect(speaking.voiceActivity == .speaking)
    }

    @Test("Nothing owed is plain listening")
    func idleListening() {
        let listening = state(status: "Listening", working: false)
        #expect(listening.displayedStatus == "Listening")
        #expect(listening.voiceActivity == .listening)
    }

    @Test("A muted microphone still shows the tutor at work, but the mark stays muted")
    func mutedWhileWorking() {
        let muted = state(status: "Listening", muted: true, working: true)
        #expect(muted.displayedStatus == "Thinking")
        #expect(muted.voiceActivity == .muted)

        let mutedIdle = state(status: "Listening", muted: true, working: false)
        #expect(mutedIdle.displayedStatus == "Microphone Off")
        #expect(mutedIdle.voiceActivity == .muted)
    }

    @Test("Outside a conversation the working flag is ignored")
    func notConversing() {
        let idle = state(phase: .idle, status: "", working: true)
        #expect(idle.displayedStatus == "Ready")
        #expect(idle.voiceActivity == .idle)

        let ending = state(phase: .ending, status: "Ending…", working: true)
        #expect(ending.voiceActivity == .ending)
    }
}
