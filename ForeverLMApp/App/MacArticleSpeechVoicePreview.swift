#if os(macOS)
import AVFoundation
import Foundation
import OSLog
import SwiftUI

enum MacArticleSpeechVoicePreviewCache {
    static let sampleText = ArticleSpeechVoicePreviewRepository.sampleText

    static func cacheKey(provider: MacArticleSpeechMode, model: String, voice: String) -> String {
        ArticleSpeechAudioCache.key(parts: cacheParts(provider: provider, model: model, voice: voice))
    }

    static func cacheParts(provider: MacArticleSpeechMode, model: String, voice: String) -> [String] {
        let speed = String(format: "%.3f", MacArticleSpeechSpeed.defaultSpeed)
        var parts = ["voice-preview", "macos", provider.rawValue, model, voice, speed, sampleText]
        switch provider {
        case .openAI:
            if model.contains("gpt-4o-mini-tts") {
                let instructions = Preferences.value(Prefs.ReadAloud.openAIInstructions)
                    ?? "Read in a calm, natural audiobook style with gentle pacing, clear pronunciation, and low intensity suitable for bedtime listening."
                parts.append(instructions)
            }
        case .groq:
            parts.append(model.hasPrefix("canopylabs/orpheus") ? "wav" : "mp3")
        case .localQwen3:
            parts.append(MacArticleSpeechSettings.localQwen3ServerURL)
            let instructions = Preferences.value(Prefs.ReadAloud.localQwen3Instructions)
                ?? "Read in a calm, natural audiobook style with gentle pacing, clear pronunciation, and low intensity suitable for bedtime listening."
            parts.append(instructions)
        default:
            break
        }
        return parts
    }

    static func data(provider: MacArticleSpeechMode, model: String, voice: String) -> Data? {
        ArticleSpeechAudioCache.data(for: cacheKey(provider: provider, model: model, voice: voice))
    }

    static func save(_ data: Data, provider: MacArticleSpeechMode, model: String, voice: String) {
        ArticleSpeechAudioCache.save(data, for: cacheKey(provider: provider, model: model, voice: voice))
    }
}

@MainActor
final class MacArticleSpeechVoicePreviewService: NSObject, ObservableObject {
    static let sampleText = MacArticleSpeechVoicePreviewCache.sampleText

    @Published private(set) var loadingVoice: String?
    @Published private(set) var playingVoice: String?
    @Published private(set) var lastError: String?

    private var audioPlayer: AVAudioPlayer?
    private let synthesizer = AVSpeechSynthesizer()
    private var playbackTask: Task<Void, Never>?
    private var isApplePreviewSpeaking = false
    private var memoryCache: [String: Data] = [:]
    private var generationTasks: [String: Task<Data, Error>] = [:]

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func isLoading(_ voice: String) -> Bool {
        loadingVoice == voice
    }

    func isPlaying(_ voice: String) -> Bool {
        playingVoice == voice
    }

    func togglePreview(provider: MacArticleSpeechMode, model: String, voice: String) {
        if isPlaying(voice) {
            stopPlayback()
            return
        }
        stopPlayback()
        lastError = nil
        if provider == .apple {
            playApple(voice: voice)
            return
        }

        let cacheKey = MacArticleSpeechVoicePreviewCache.cacheKey(
            provider: provider,
            model: model,
            voice: voice
        )

        if let cached = memoryCache[cacheKey] {
            do {
                try playAudio(cached, voice: voice)
            } catch {
                lastError = error.localizedDescription
            }
            return
        }

        loadingVoice = voice
        playbackTask = Task {
            defer {
                if loadingVoice == voice {
                    loadingVoice = nil
                }
            }
            do {
                let data = try await cachedOrGeneratedPreview(
                    cacheKey: cacheKey,
                    provider: provider,
                    model: model,
                    voice: voice
                )
                memoryCache[cacheKey] = data
                guard !Task.isCancelled else { return }
                try playAudio(data, voice: voice)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                lastError = error.localizedDescription
                Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "MacArticleSpeechVoicePreviewService")
                    .error("Preview failed: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        playbackTask?.cancel()
        playbackTask = nil
        stopPlayback()
    }

    func prewarmAllModels(prioritizedModelID: String) {
        Task {
            await ArticleSpeechVoicePreviewRepository.shared.startPrewarming(
                prioritizedModelID: prioritizedModelID
            )
        }
    }

    private func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        if isApplePreviewSpeaking {
            isApplePreviewSpeaking = false
            synthesizer.stopSpeaking(at: .immediate)
        }
        loadingVoice = nil
        playingVoice = nil
    }

    private func cachedOrGeneratedPreview(
        cacheKey: String,
        provider: MacArticleSpeechMode,
        model: String,
        voice: String
    ) async throws -> Data {
        if provider == .openRouter,
           ArticleSpeechCatalog.model(id: model)?.voice(id: voice) != nil {
            return try await ArticleSpeechVoicePreviewRepository.shared.audio(
                modelID: model,
                voiceID: voice
            )
        }

        if let existing = generationTasks[cacheKey] {
            return try await existing.value
        }

        let task = Task.detached {
            if let cached = MacArticleSpeechVoicePreviewCache.data(
                provider: provider,
                model: model,
                voice: voice
            ) {
                return cached
            }

            let data = try await MacArticleTTSClient.speech(
                provider: provider,
                text: MacArticleSpeechVoicePreviewCache.sampleText,
                speed: MacArticleSpeechSpeed.defaultSpeed,
                model: model,
                voice: voice,
                task: "voice_preview"
            )
            MacArticleSpeechVoicePreviewCache.save(
                data,
                provider: provider,
                model: model,
                voice: voice
            )
            return data
        }
        generationTasks[cacheKey] = task
        defer { generationTasks.removeValue(forKey: cacheKey) }
        return try await task.value
    }

    private func playApple(voice: String) {
        let utterance = AVSpeechUtterance(string: Self.sampleText)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        if !voice.isEmpty, let avVoice = AVSpeechSynthesisVoice(identifier: voice) {
            utterance.voice = avVoice
        }
        playingVoice = voice.isEmpty ? "system" : voice
        isApplePreviewSpeaking = true
        synthesizer.speak(utterance)
    }

    private func playAudio(_ data: Data, voice: String) throws {
        let player = try AVAudioPlayer(data: data)
        player.delegate = self
        player.prepareToPlay()
        audioPlayer = player
        playingVoice = voice
        guard player.play() else {
            playingVoice = nil
            throw MacArticleTTSError.badResponse("Preview playback could not start.")
        }
    }
}

extension MacArticleSpeechVoicePreviewService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            isApplePreviewSpeaking = false
            playingVoice = nil
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            isApplePreviewSpeaking = false
            playingVoice = nil
        }
    }
}

extension MacArticleSpeechVoicePreviewService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            audioPlayer = nil
            playingVoice = nil
        }
    }
}
#endif
