import Foundation

extension RealtimeVoiceController {
    /// Voice mode on the shared voice screen (`VoiceSessionSurface`), on the Mac
    /// and the iPhone alike. `context` is the source card under the mark.
    func presentationState(context: VoiceContextItem?) -> VoiceSessionPresentationState {
        let surfacePhase: VoiceSessionPhase
        switch phase {
        case .idle: surfacePhase = .idle
        case .connecting, .reconnecting: surfacePhase = .connecting
        case .live: surfacePhase = .live
        case .ending: surfacePhase = .ending
        case .failed: surfacePhase = .failed
        }
        return VoiceSessionPresentationState(
            phase: surfacePhase,
            statusText: statusText,
            headerTitle: title ?? "Voice",
            headerSystemImage: opening == .quiz ? "questionmark.bubble" : "waveform",
            contextItems: context.map { [$0] } ?? [],
            isMicrophoneMuted: isMicrophoneMuted,
            microphoneLevel: microphoneLevel,
            terminalErrorMessage: phase == .failed ? errorMessage : nil,
            inlineErrorMessage: phase == .failed ? nil : errorMessage,
            isTutorWorking: isTutorWorking,
            // Voice mode shows no words while it talks (product owner,
            // 2026-11-07): the conversation is heard, not read.
            caption: nil
        )
    }
}
