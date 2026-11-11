#if os(macOS)
import AVFoundation
import Combine
import Foundation

@MainActor
final class ReviewSpeechService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false
    @Published private(set) var currentMessageID: UUID?
    @Published var errorMessage: String?

    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var playbackTask: Task<Void, Never>?
    private var currentUtterance: AVSpeechUtterance?
    private var audioChunks: [String] = []
    private var audioChunkIndex = 0
    private var audioGenerationID = UUID()
    private var activeMode: MacArticleSpeechMode = .apple
    private var activeVoice = ""

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, messageID: UUID? = nil) {
        let spokenText = Self.spokenText(from: text)
        guard let speakableText = MacArticleSpeechText.speakableInput(from: spokenText) else { return }

        stopPlayback()
        errorMessage = nil
        currentMessageID = messageID
        isSpeaking = true
        isPaused = false

        activeMode = MacArticleSpeechSettings.provider
        activeVoice = MacArticleSpeechSettings.voice(for: activeMode)

        guard activeMode.isCloudProvider else {
            speakWithApple(speakableText)
            return
        }

        audioChunks = Self.chunk(speakableText, maxLength: Self.chunkLimit(for: activeMode))
        guard !audioChunks.isEmpty else {
            finishSpeaking()
            return
        }
        audioChunkIndex = 0
        let generationID = UUID()
        audioGenerationID = generationID

        playbackTask = Task { [weak self] in
            await self?.playNextCloudChunk(generationID: generationID)
        }
    }

    private func speakWithApple(_ spokenText: String) {
        let utterance = AVSpeechUtterance(string: spokenText)
        utterance.prefersAssistiveTechnologySettings = false
        utterance.rate = Self.appleSpeechRate()
        utterance.pitchMultiplier = 0.95
        if let voiceIdentifier = MacArticleSpeechSettings.appleVoiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        }
        currentUtterance = utterance
        synthesizer.speak(utterance)
    }

    func pauseOrResume() {
        guard isSpeaking else { return }
        if activeMode.isCloudProvider {
            guard let audioPlayer else { return }
            if audioPlayer.isPlaying {
                audioPlayer.pause()
                isPaused = true
            } else {
                audioPlayer.play()
                isPaused = false
            }
            return
        }

        if synthesizer.isPaused {
            synthesizer.continueSpeaking()
            isPaused = false
        } else {
            synthesizer.pauseSpeaking(at: .word)
            isPaused = true
        }
    }

    func stop() {
        stopPlayback()
    }

    private func playNextCloudChunk(generationID: UUID) async {
        guard generationID == audioGenerationID else { return }
        guard audioChunkIndex < audioChunks.count else {
            finishSpeaking()
            return
        }

        do {
            let chunk = audioChunks[audioChunkIndex]
            let mode = activeMode
            let voice = activeVoice
            let data = try await MacArticleTTSClient.speech(
                provider: mode,
                text: chunk,
                speed: MacArticleSpeechSpeed.defaultSpeed,
                voice: voice,
                task: "review_speech"
            )
            guard generationID == audioGenerationID, !Task.isCancelled else { return }

            audioChunkIndex += 1
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.enableRate = true
            player.rate = Self.audioPlaybackRate()
            player.prepareToPlay()
            audioPlayer = player
            isPaused = false

            guard player.play() else {
                throw MacArticleTTSError.badResponse("Audio playback could not start.")
            }
        } catch {
            guard generationID == audioGenerationID, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            // Notify even though nothing was spoken. The voice-conversation loop
            // opens the mic only on this callback, so swallowing it here left
            // voice mode switched on with a dead microphone — the tutor's voice
            // failing silently took dictation down with it. The failure is not
            // masked: `errorMessage` still raises the composer's error banner.
            // It just no longer costs the user their turn.
            finishSpeaking()
        }
    }

    private func stopPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        audioGenerationID = UUID()
        synthesizer.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        audioPlayer = nil
        audioChunks = []
        audioChunkIndex = 0
        finishSpeaking(utterance: currentUtterance)
    }

    private func finishSpeaking(utterance: AVSpeechUtterance?) {
        if let utterance {
            guard let currentUtterance,
                  utterance === currentUtterance else { return }
        }
        currentUtterance = nil
        isSpeaking = false
        isPaused = false
        currentMessageID = nil
    }

    private func finishSpeaking() {
        playbackTask?.cancel()
        playbackTask = nil
        audioPlayer = nil
        audioChunks = []
        audioChunkIndex = 0
        finishSpeaking(utterance: nil)
    }

    private static func appleSpeechRate() -> Float {
        let storedSpeed = Preferences.value(Prefs.ReadAloud.speed)
        let speed = MacArticleSpeechSpeed.clamped(storedSpeed ?? MacArticleSpeechSpeed.defaultSpeed)
        let normalReadingRate: Float = 0.16
        let scaledRate = normalReadingRate * Float(speed)
        return min(max(scaledRate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
    }

    private static func audioPlaybackRate() -> Float {
        let storedSpeed = Preferences.value(Prefs.ReadAloud.speed)
        let speed = MacArticleSpeechSpeed.clamped(storedSpeed ?? MacArticleSpeechSpeed.defaultSpeed)
        return min(max(Float(speed), 0.5), 2.0)
    }

    private static func chunkLimit(for provider: MacArticleSpeechMode) -> Int {
        switch provider {
        case .groq:
            if MacArticleSpeechSettings.groqModel == MacArticleSpeechSettings.defaultGroqModel {
                return 180
            }
            return 1_000
        case .openRouter, .openAI, .togetherAI, .elevenLabs, .xai, .gemini, .localQwen3:
            return 1_000
        case .apple:
            return 3_500
        }
    }

    private static func chunk(_ text: String, maxLength: Int) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var chunks: [String] = []
        var current = ""
        let paragraphs = normalized
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for paragraph in paragraphs {
            let candidate = current.isEmpty ? paragraph : "\(current)\n\n\(paragraph)"
            if candidate.count <= maxLength {
                current = candidate
            } else {
                if !current.isEmpty {
                    chunks.append(current)
                }
                if paragraph.count <= maxLength {
                    current = paragraph
                } else {
                    chunks.append(contentsOf: wordChunks(paragraph, maxLength: maxLength))
                    current = ""
                }
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks.compactMap { MacArticleSpeechText.speakableInput(from: $0) }
    }

    private static func wordChunks(_ text: String, maxLength: Int) -> [String] {
        var result: [String] = []
        var current = ""

        for word in text.split(separator: " ") {
            let candidate = current.isEmpty ? String(word) : "\(current) \(word)"
            if candidate.count <= maxLength {
                current = candidate
            } else {
                if !current.isEmpty {
                    result.append(current)
                }
                current = String(word)
            }
        }

        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    static func spokenText(from text: String) -> String {
        var result = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\t", with: " ")

        result = replacing(pattern: #"```[\s\S]*?```"#, in: result, with: " ")
        result = replacing(pattern: #"`([^`]+)`"#, in: result, with: "$1")
        result = replacing(pattern: #"\!\[([^\]]*)\]\([^)]+\)"#, in: result, with: "$1")
        result = replacing(pattern: #"\[([^\]]+)\]\([^)]+\)"#, in: result, with: "$1")
        result = replacing(pattern: #"(?m)^\s{0,3}#{1,6}\s*"#, in: result, with: "")
        result = replacing(pattern: #"(?m)^\s*[-*+]\s+"#, in: result, with: "")
        result = replacing(pattern: #"(?m)^\s*\d+\.\s+"#, in: result, with: "")
        result = replacing(pattern: #"<[^>]+>"#, in: result, with: " ")
        result = result.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: ">", with: "")

        result = replacing(pattern: #"[ \u{00A0}]{2,}"#, in: result, with: " ")
        result = replacing(pattern: #"\n{3,}"#, in: result, with: "\n\n")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacing(pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.finishSpeaking(utterance: utterance)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.finishSpeaking(utterance: utterance)
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.audioPlayer === player else { return }
            guard flag else {
                self.errorMessage = "Audio playback stopped before the current segment finished."
                self.finishSpeaking()
                return
            }
            let generationID = self.audioGenerationID
            self.playbackTask = Task { [weak self] in
                await self?.playNextCloudChunk(generationID: generationID)
            }
        }
    }
}
#endif
