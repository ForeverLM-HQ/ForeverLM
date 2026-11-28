// Splitting narration into chunks and the chunk limits per provider.
#if os(macOS)
import AVFoundation
import Foundation
import SwiftUI

extension ArticleSpeechService {
    /// Splits already-cleaned narration text into provider-sized chunks. Takes
    /// the output of `MacArticleSpeechText.narrationText(from:)` so callers that
    /// computed it once (off-main) do not pay for the cleanup regexes again.
    /// `leadChunkCount` opening chunks are held to `firstChunkMaxLength` — a few
    /// sentences each — before full-size chunks take over. One short chunk only
    /// buys the first word; the chunks right behind it are the ones playback
    /// runs into next, and at full size they arrive slower than they are heard.
    nonisolated static func narrationChunks(
        from reflowed: String,
        maxLength: Int,
        firstChunkMaxLength: Int? = nil,
        leadChunkCount: Int = 1
    ) -> [String] {
        var chunks: [String] = []
        var current = ""
        let leadLimit = min(firstChunkMaxLength ?? maxLength, maxLength)
        let leadChunks = max(leadChunkCount, 0)
        func limit(forChunkAt index: Int) -> Int {
            index < leadChunks ? leadLimit : maxLength
        }
        var currentLimit = limit(forChunkAt: 0)

        func flushCurrent() {
            guard !current.isEmpty else { return }
            chunks.append(current)
            current = ""
            currentLimit = limit(forChunkAt: chunks.count)
        }

        let paragraphs = reflowed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for paragraph in paragraphs {
            // Paragraphs are indivisible whenever the provider limit permits,
            // but several consecutive paragraphs share one synthesis request.
            // The extra context lets the voice carry pacing and intonation
            // forward instead of restarting its prosody after every paragraph.
            let fillingLeadChunk = currentLimit < maxLength
            let candidate = current.isEmpty ? paragraph : "\(current)\n\n\(paragraph)"
            if candidate.count <= currentLimit {
                current = candidate
                continue
            }

            // The paragraph won't fit on the open chunk. Close the accumulated
            // paragraphs and start this one on a fresh request. The fast lead is
            // the exception: flushing it underfilled can ship a bare heading, so
            // fill its remaining room with whole sentences from the first body
            // paragraph and start playback promptly.
            if !fillingLeadChunk {
                flushCurrent()
                if paragraph.count <= currentLimit {
                    current = paragraph
                    continue
                }
            }

            // Pack whole sentences so any split lands at a sentence boundary — a
            // natural pause — instead of mid-sentence. This matters most for
            // Orpheus's tiny 180-char chunks, where every chunk boundary is an
            // audible gap between separately generated audio clips.
            var joiner = "\n\n"
            for sentence in CloudArticleTTS.sentences(in: paragraph) {
                let sentenceCandidate = current.isEmpty ? sentence : "\(current)\(joiner)\(sentence)"
                joiner = " "
                if sentenceCandidate.count <= currentLimit {
                    current = sentenceCandidate
                } else {
                    flushCurrent()
                    if sentence.count <= currentLimit {
                        current = sentence
                    } else {
                        // A single sentence longer than the limit still has to be
                        // broken; fall back to word boundaries for just this sentence.
                        chunks.append(contentsOf: wordChunks(
                            sentence,
                            maxLength: maxLength,
                            firstChunkMaxLength: currentLimit
                        ))
                        current = ""
                        currentLimit = limit(forChunkAt: chunks.count)
                    }
                }
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks.compactMap { MacArticleSpeechText.speakableInput(from: $0) }
    }

    private nonisolated static func wordChunks(_ text: String, maxLength: Int, firstChunkMaxLength: Int? = nil) -> [String] {
        var result: [String] = []
        var current = ""
        var currentLimit = min(firstChunkMaxLength ?? maxLength, maxLength)

        for word in text.split(separator: " ") {
            let candidate = current.isEmpty ? String(word) : "\(current) \(word)"
            if candidate.count <= currentLimit {
                current = candidate
            } else {
                if !current.isEmpty {
                    result.append(current)
                    currentLimit = maxLength
                }
                current = String(word)
            }
        }

        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    static func appleSpeechRate(for speed: Double) -> Float {
        let normalReadingRate: Float = 0.16
        let scaledRate = normalReadingRate * Float(MacArticleSpeechSpeed.clamped(speed))
        return min(max(scaledRate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
    }

    static func audioPlaybackRate(for speed: Double) -> Float {
        min(max(Float(MacArticleSpeechSpeed.clamped(speed)), 0.5), Float(MacArticleSpeechSpeed.maximum))
    }

    static func syncedAudioFileExtension(provider: MacArticleSpeechMode, model: String) -> String {
        switch provider {
        case .groq:
            return model.hasPrefix("canopylabs/orpheus") ? "wav" : "mp3"
        case .openRouter:
            return ArticleSpeechCatalog.model(id: model)?.responseFormat.storedFileExtension ?? "mp3"
        case .openAI, .togetherAI, .elevenLabs, .xai:
            return "mp3"
        case .gemini:
            // Gemini returns raw PCM; the client transcodes it to AAC in an m4a container.
            return "m4a"
        case .localQwen3:
            return "wav"
        case .apple:
            return "mp3"
        }
    }

    private nonisolated static func isOrpheusModel(_ model: String) -> Bool {
        model.hasPrefix("canopylabs/orpheus")
    }

    /// `model` is the model this generation will actually use, which is not
    /// always the stored selection: a source in another language can be routed
    /// to a voice that speaks it, and the chunk plan has to follow.
    nonisolated static func chunkLimit(
        for provider: MacArticleSpeechMode,
        model: String
    ) -> Int {
        switch provider {
        case .openRouter:
            // Orpheus keeps its short-input limit on every host; the rest of
            // the OpenRouter catalog carries its own per-model unit size, which
            // the iPhone reads from the same place.
            if isOrpheusModel(model) { return orpheusChunkLimit }
            return ArticleSpeechCatalog.chunkLimit(forModel: model)
        case .groq:
            return isOrpheusModel(MacArticleSpeechSettings.groqModel) ? orpheusChunkLimit : 4_000
        case .openAI:
            // Smaller chunks generate faster, so each later segment is ready well before
            // playback reaches it — keeps audio gapless after the quick first-chunk start.
            return 2_000
        case .togetherAI:
            // The default TogetherAI model is canopylabs/orpheus-3b, which has the same
            // short-input limit as Groq's Orpheus; only the non-Orpheus voices
            // (Cartesia, Rime, Minimax) can take the larger chunk.
            return isOrpheusModel(MacArticleSpeechSettings.togetherAIModel) ? orpheusChunkLimit : 3_000
        case .elevenLabs:
            let model = MacArticleSpeechSettings.elevenLabsModel
            if model == "eleven_v3" {
                return 2_800
            }
            if model == "eleven_multilingual_v2" {
                return 8_000
            }
            if model.contains("flash") || model.contains("turbo") {
                return 8_000
            }
            return 5_000
        case .xai:
            return 14_000
        case .gemini:
            // The TTS models take up to a 32k-token session; chunks stay small so
            // seek and resume keep paragraph granularity.
            return 3_500
        case .localQwen3:
            return 1_500
        case .apple:
            return 3_500
        }
    }

    private nonisolated static func leadChunkLimit(
        for provider: MacArticleSpeechMode,
        model: String
    ) -> Int {
        switch provider {
        case .openAI, .gemini:
            // gpt-4o-mini-tts and Gemini TTS latency scale with input length, so a
            // shorter lead chunk gets the first audio playing noticeably sooner.
            return 500
        case .openRouter:
            return isOrpheusModel(model)
                ? playbackLeadChunkLimit
                : ArticleSpeechCatalog.leadChunkLimit(forModel: model)
        case .groq, .togetherAI, .elevenLabs, .xai, .localQwen3, .apple:
            return playbackLeadChunkLimit
        }
    }

    /// How many opening chunks stay at the lead size. Three short requests get
    /// audio playing and keep the buffer ahead of the playhead through the first
    /// minute, which is where a fresh source is most likely to run dry.
    nonisolated static func leadChunkCount(for provider: MacArticleSpeechMode) -> Int {
        switch provider {
        case .apple:
            // Local synthesis has no per-request latency to hide.
            return 1
        case .openRouter, .groq, .openAI, .togetherAI, .elevenLabs, .xai, .gemini, .localQwen3:
            return 3
        }
    }

    nonisolated static func firstChunkLimit(
        for provider: MacArticleSpeechMode,
        model: String
    ) -> Int? {
        let maxLength = chunkLimit(for: provider, model: model)
        let leadLimit = leadChunkLimit(for: provider, model: model)
        guard maxLength > leadLimit else { return nil }
        return leadLimit
    }

    nonisolated static let maxChunkGenerationAttempts = 8

    nonisolated static func chunkRetryDelayNanoseconds(attempt: Int) -> UInt64 {
        let seconds = min(pow(2.0, Double(attempt - 1)), 16.0) + Double.random(in: 0.25...1.0)
        return UInt64(seconds * 1_000_000_000)
    }

    static func backgroundAudioCacheConcurrency(for provider: MacArticleSpeechMode) -> Int {
        switch provider {
        case .elevenLabs:
            return 4
        case .openRouter, .openAI, .togetherAI, .xai, .gemini:
            // A narration kept for later has nothing to play while it is made,
            // so how many parts are in flight sets how long the learner waits:
            // Gemini TTS takes ~45 s a part, a 100,000-character source is
            // ~125 parts, and six at a time was 30 minutes. The proxy admits 120
            // requests a minute a connection and a 429 is retried with backoff,
            // so 40 in flight is well inside both: a 105-part narration is
            // three rounds, not eighteen.
            return 40
        case .groq:
            return 8
        case .localQwen3:
            return 2
        case .apple:
            return 1
        }
    }

    func providerVoiceLabel(
        provider: MacArticleSpeechMode,
        voice: String,
        model: String? = nil
    ) -> String {
        switch provider {
        case .openRouter:
            return ArticleSpeechCatalog.voiceLabel(
                model: model ?? MacArticleSpeechSettings.openRouterModel,
                voice: voice
            )
        case .elevenLabs:
            return MacArticleSpeechSettings.elevenLabsVoicePresets.first(where: { $0.id == voice })?.name ?? voice
        case .togetherAI:
            return voice.replacingOccurrences(of: "_", with: " ").capitalized
        case .groq:
            return voice.capitalized
        case .openAI:
            return voice.capitalized
        case .xai:
            return MacArticleSpeechSettings.xaiVoiceLabel(for: voice)
        case .gemini:
            return voice
        case .localQwen3:
            return voice.replacingOccurrences(of: "_", with: " ")
        case .apple:
            return MacArticleSpeechSettings.appleVoiceName(
                identifier: activeAppleVoiceIdentifier ?? appleVoiceIdentifier
            )
        }
    }
}
#endif
