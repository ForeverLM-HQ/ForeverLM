import AVFoundation
import Foundation

@MainActor
final class MobileReviewSpeechService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    // One synthesizer for the whole app. Separate AVSpeechSynthesizer instances do
    // not stop each other, so a second one would let the Voice tab and the reading
    // chat talk over one another and let one instance's finish callback re-arm a
    // microphone while the other is still speaking.
    static let shared = MobileReviewSpeechService()

    // Which surface queued what is currently being spoken. One synthesizer with
    // several drivers means an unqualified stop() is a cross-surface kill: the
    // reading chat could cut off a Voice-tab review mid-utterance and, because
    // stopping also suppresses the finish callback, strand it with the mic never
    // re-armed. A stop only lands if it comes from the surface that spoke.
    enum SpeechOwner: Equatable, Sendable {
        case voiceTab
        case readingChat
        /// The turn-by-turn voice conversation (`MobileVoiceConversationController`),
        /// which always passes its own finish handler.
        case voiceConversation
        case watch
    }

    @Published private(set) var isSpeaking = false

    var onFinishSpeaking: (() -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private var activeUtteranceIDs: Set<ObjectIdentifier> = []
    private var shouldNotifyFinish = false
    private var currentOwner: SpeechOwner?
    private var onFinishCurrentUtterance: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, owner: SpeechOwner, onFinish: (() -> Void)? = nil) {
        let spokenText = Self.spokenText(from: text)
        guard !spokenText.isEmpty else {
            (onFinish ?? onFinishSpeaking)?()
            return
        }

        shouldNotifyFinish = false
        synthesizer.stopSpeaking(at: .immediate)

        let chunks = Self.speechChunks(from: spokenText)
        let utterances = chunks.map { chunk in
            let utterance = AVSpeechUtterance(string: chunk)
            utterance.prefersAssistiveTechnologySettings = false
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
            utterance.pitchMultiplier = 0.98
            utterance.preUtteranceDelay = 0.02
            utterance.postUtteranceDelay = 0.06
            return utterance
        }

        activeUtteranceIDs = Set(utterances.map(ObjectIdentifier.init))
        shouldNotifyFinish = true
        isSpeaking = true
        currentOwner = owner
        onFinishCurrentUtterance = onFinish

        for utterance in utterances {
            synthesizer.speak(utterance)
        }
    }

    func stop(owner: SpeechOwner) {
        guard currentOwner == owner else { return }
        shouldNotifyFinish = false
        activeUtteranceIDs = []
        onFinishCurrentUtterance = nil
        currentOwner = nil
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.completeUtterance(utterance)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.completeUtterance(utterance)
        }
    }

    private func completeUtterance(_ utterance: AVSpeechUtterance) {
        guard shouldNotifyFinish else { return }
        activeUtteranceIDs.remove(ObjectIdentifier(utterance))
        guard activeUtteranceIDs.isEmpty else { return }

        shouldNotifyFinish = false
        isSpeaking = false

        // `onFinishSpeaking` is the instance owner's standing handler — the Voice tab
        // installs one on the shared singleton, the watch on its own instance. The
        // reading chat is a guest on that same singleton, so inheriting the fallback
        // would end every chat reply by running the Voice tab's resumeAfterSpeech and
        // re-arming its microphone against speech the Voice tab never started.
        let owner = currentOwner
        let completion = onFinishCurrentUtterance
            ?? (owner == .readingChat || owner == .voiceConversation ? nil : onFinishSpeaking)
        onFinishCurrentUtterance = nil
        currentOwner = nil
        completion?()
    }

    nonisolated static func spokenText(from text: String) -> String {
        var result = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\t", with: " ")
        result = replacing(pattern: #"```[\s\S]*?```"#, in: result, with: " ")
        result = replacing(pattern: #"`([^`]+)`"#, in: result, with: "$1")
        result = replacing(pattern: #"\!\[([^\]]*)\]\([^)]+\)"#, in: result, with: "$1")
        result = replacing(pattern: #"\[([^\]]+)\]\([^)]+\)"#, in: result, with: "$1")
        // Bracketed numeric reference marks like [63], [1, 2], or [3–5] are
        // citation noise when spoken; must run after markdown-link unwrapping.
        result = replacing(pattern: #"\s*\[\s*\d+(?:\s*[-–—,;]\s*\d+)*\s*\]"#, in: result, with: "")
        result = replacing(pattern: #"[ \t]+([.,;:!?])"#, in: result, with: "$1")
        result = replacing(pattern: #"(?m)^\s{0,3}#{1,6}\s*"#, in: result, with: "")
        result = replacing(pattern: #"(?m)^\s*[-*+]\s+"#, in: result, with: "")
        result = replacing(pattern: #"(?m)^\s*\d+\.\s+"#, in: result, with: "")
        result = replacing(pattern: #"<[^>]+>"#, in: result, with: " ")
        result = result
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: ">", with: "")
        result = replacing(pattern: #"[ \u{00A0}]{2,}"#, in: result, with: " ")
        result = replacing(pattern: #"\n{3,}"#, in: result, with: "\n\n")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// PDF (and some HTML) extractors emit a hard line break at every visual line
    /// end, so a single sentence arrives split across several lines. Feeding those
    /// breaks to the synthesizer reads with an audible stop mid-sentence. Rejoin
    /// soft-wrapped lines into flowing paragraphs — de-hyphenating words broken
    /// across a line — while preserving genuine paragraph breaks (blank lines).
    /// Mirrors `MacArticleSpeechText.reflowedForSpeech` so both platforms narrate
    /// extracted source text the same way.
    nonisolated static func reflowedForSpeech(_ text: String) -> String {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var paragraphs: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { paragraphs.append(trimmed) }
            current = ""
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if current.isEmpty {
                current = line
            } else if current.hasSuffix("-"),
                      let previous = current.dropLast().last, previous.isLetter,
                      let first = line.first, first.isLowercase {
                // A word hyphenated across the line break (e.g. "abroga-\ntion"):
                // drop the trailing hyphen and join tight so it reads as one word.
                current.removeLast()
                current += line
            } else {
                current += " " + line
            }
        }
        flush()

        return paragraphs.joined(separator: "\n\n")
    }

    /// Narration is lossless. Meaning-sensitive condensation belongs in a
    /// configurable AI preparation task, not hand-written text rules.
    nonisolated static func narrationText(from raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func speechChunks(from text: String, maxLength: Int = 3_500) -> [String] {
        let paragraphs = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var chunks: [String] = []
        var current = ""

        for paragraph in paragraphs {
            if paragraph.count > maxLength {
                if !current.isEmpty {
                    chunks.append(current)
                    current = ""
                }
                chunks.append(contentsOf: splitLongText(paragraph, maxLength: maxLength))
                continue
            }

            if current.isEmpty {
                current = paragraph
            } else if current.count + paragraph.count + 2 <= maxLength {
                current += "\n\n\(paragraph)"
            } else {
                chunks.append(current)
                current = paragraph
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }

        return chunks.isEmpty ? [text] : chunks
    }

    private nonisolated static func splitLongText(_ text: String, maxLength: Int) -> [String] {
        var chunks: [String] = []
        var remainder = text

        while remainder.count > maxLength {
            let splitIndex = bestSplitIndex(in: remainder, maxLength: maxLength)
            let chunk = String(remainder[..<splitIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty {
                chunks.append(chunk)
            }
            remainder = String(remainder[splitIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if !remainder.isEmpty {
            chunks.append(remainder)
        }

        return chunks
    }

    private nonisolated static func bestSplitIndex(in text: String, maxLength: Int) -> String.Index {
        let upperBound = text.index(text.startIndex, offsetBy: min(maxLength, text.count))
        let candidate = text[..<upperBound]
        if let sentence = candidate.lastIndex(where: { ".?!".contains($0) }) {
            return text.index(after: sentence)
        }
        if let space = candidate.lastIndex(where: { $0.isWhitespace }) {
            return space
        }
        return upperBound
    }

    private nonisolated static func replacing(pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }

}
