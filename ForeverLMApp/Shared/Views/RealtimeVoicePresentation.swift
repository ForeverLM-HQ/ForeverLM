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
            headerSystemImage: {
                switch opening {
                case .talk: return "waveform"
                case .quiz: return "questionmark.bubble"
                case .gym: return "figure.strengthtraining.traditional"
                }
            }(),
            contextItems: context.map { [$0] } ?? [],
            isMicrophoneMuted: isMicrophoneMuted,
            microphoneLevel: microphoneLevel,
            terminalErrorMessage: phase == .failed ? errorMessage : nil,
            inlineErrorMessage: phase == .failed ? nil : errorMessage,
            isTutorWorking: isTutorWorking
        )
    }
}
