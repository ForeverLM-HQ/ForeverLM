import Foundation
import Testing
@testable import ForeverLM

/// Where a stored podcast transcript stops inside its episode's TTML text, and
/// whether that stop is the retired 50,000-character import cap. The episodes
/// are synthetic but shaped like the extractor's output (a speaker label on its
/// own line before each turn) and cut the way the real ones were: on
/// 2026-10-06 every capped episode in a real library stopped at character
/// 49,984 to 50,000 of its episode text, half of them inside a word, while the
/// twenty-odd complete ones that stop early had lost a closing sponsor read or
/// outro to the ad pass.
@Suite("Podcast transcript completeness")
struct PodcastTranscriptCompletenessTests {
    private typealias Completeness = PodcastTranscriptCompleteness

    /// An episode's text as `SourceService.extractTextFromTTMLContent` lays it
    /// out. Every word is distinct (`word1` … `wordN`), so a fixture's ending is
    /// found in exactly one place unless a test repeats a passage on purpose.
    /// At 8 sentences of 9 words a turn, the retired cap falls inside `Word5500`
    /// (characters 49,995 to 50,002).
    private static func episode(turns: Int, firstWord: Int = 1) -> String {
        var parts: [String] = []
        var n = firstWord - 1
        for turn in 0..<turns {
            var sentences: [String] = []
            for _ in 0..<8 {
                var words: [String] = []
                for _ in 0..<9 {
                    n += 1
                    words.append("Word\(n)")
                }
                sentences.append(words.joined(separator: " ") + ".")
            }
            parts.append("[SPEAKER_\(turn % 2 + 1)]\n" + sentences.joined(separator: " "))
        }
        return parts.joined(separator: "\n\n")
    }

    /// What the formatting pass makes of raw text: speaker names for the
    /// diarized labels, and a named marker where it starts a new paragraph.
    private static func formatted(_ text: String) -> String {
        text.replacingOccurrences(of: "[SPEAKER_1]", with: "[Ada Lovelace]")
            .replacingOccurrences(of: "[SPEAKER_2]", with: "[Charles Babbage]")
            .replacingOccurrences(of: "Word108. ", with: "Word108.\n\n**Ada Lovelace:** ")
    }

    private static func prefix(_ text: String, _ count: Int) -> String {
        String(text.prefix(count))
    }

    /// The text from character `start` to the end, dropping the rest.
    private static func removing(_ text: String, from start: Int, upTo end: Int) -> String {
        let lower = text.index(text.startIndex, offsetBy: start)
        let upper = text.index(text.startIndex, offsetBy: end)
        return String(text[..<lower]) + String(text[upper...])
    }

    private static let longEpisode = episode(turns: 120)

    @Test("The fixture's cap falls inside a word, where a real one usually did")
    func fixtureShape() {
        let text = Self.longEpisode
        #expect(text.count == 79_171)
        let around = Array(text)[49_990..<50_005]
        #expect(String(around) == "499. Word5500 W")
    }

    @Test("A transcript the cap cut inside a word is cut")
    func cappedMidWord() {
        let capped = Self.prefix(Self.longEpisode, Completeness.retiredImportCap)
        #expect(capped.hasSuffix("Word5"))
        let ending = Completeness.ending(of: capped, within: Self.longEpisode)
        #expect(ending.kind == .midWord)
        #expect(ending.episodeOffset == 50_000)
        #expect(ending.wordsAfter > 0)
        #expect(Completeness.verdict(for: ending) == .cut)
    }

    @Test("A transcript the cap cut at a word boundary just under it is cut")
    func cappedAtWordBoundary() {
        let capped = Self.prefix(Self.longEpisode, 49_994)
        #expect(capped.hasSuffix("Word5499."))
        let ending = Completeness.ending(of: capped, within: Self.longEpisode)
        #expect(ending.kind == .wholeWord)
        #expect(ending.episodeOffset == 49_993)
        #expect(Completeness.verdict(for: ending) == .cut)
    }

    @Test("Formatting and ad removal before the cut do not hide it")
    func cappedAfterFormattingAndAdRemoval() {
        // Speaker names and paragraph markers push a capped transcript past
        // 50,000 characters; an ad removed in the middle pulls it back under.
        // Neither moves where it stops in the episode.
        let capped = Self.formatted(Self.prefix(Self.longEpisode, Completeness.retiredImportCap))
        #expect(capped.count > Completeness.retiredImportCap)
        #expect(Completeness.verdict(transcript: capped, episodeText: Self.longEpisode) == .cut)

        let adRemoved = Self.removing(capped, from: 20_000, upTo: 23_000)
        #expect(adRemoved.count < Completeness.retiredImportCap - 2_000)
        let ending = Completeness.ending(of: adRemoved, within: Self.longEpisode)
        #expect(ending.episodeOffset == 50_000)
        #expect(Completeness.verdict(for: ending) == .cut)
    }

    @Test("A complete transcript, formatted or not, is complete")
    func completeTranscript() {
        let ending = Completeness.ending(of: Self.longEpisode, within: Self.longEpisode)
        #expect(ending.kind == .wholeWord)
        #expect(ending.wordsAfter == 0)
        #expect(ending.episodeOffset == ending.episodeCharacterCount - 1)
        #expect(Completeness.verdict(for: ending) == .complete)
        #expect(Completeness.verdict(transcript: Self.formatted(Self.longEpisode), episodeText: Self.longEpisode) == .complete)
        // A word past the episode's end (a sign-off the formatter kept from
        // another revision) still ends at the episode's end.
        let past = Completeness.ending(of: Self.longEpisode + " Goodbye.", within: Self.longEpisode)
        #expect(past.kind == .atEnd)
        #expect(Completeness.verdict(for: past) == .complete)
    }

    @Test("A transcript whose closing sponsor read or outro the ad pass removed is complete")
    func outroRemoved() throws {
        // The last turn, a closing read, is gone: the transcript stops after a
        // whole word, at a sentence's end, nowhere near the cap.
        let lastTurn = try #require(Self.longEpisode.range(of: "\n\n[SPEAKER_2]\n", options: .backwards))
        let trimmed = String(Self.longEpisode[..<lastTurn.lowerBound])
        let ending = Completeness.ending(of: trimmed, within: Self.longEpisode)
        #expect(ending.kind == .wholeWord)
        #expect(ending.wordsAfter == 72)
        #expect(ending.episodeOffset.map { $0 > Completeness.retiredImportCap } == true)
        #expect(Completeness.verdict(for: ending) == .complete)
    }

    @Test("A transcript with an ad removed mid-episode is complete")
    func adRemovedMidEpisode() {
        let trimmed = Self.removing(Self.longEpisode, from: 30_000, upTo: 33_500)
        #expect(Completeness.verdict(transcript: trimmed, episodeText: Self.longEpisode) == .complete)
    }

    @Test("A transcript that stops inside a speaker label is cut, at the cap or not")
    func endsInsideSpeakerLabel() throws {
        let text = Self.longEpisode
        // The shape of a real one (Lex Fridman #490, 2026-10-06): the stored
        // text had a speaker change right after the cap's last whole word, and
        // the cap fell inside its label. The label's letters are not a word;
        // the word before it ends just under the cap.
        let cutInLabel = Self.prefix(text, 49_994) + "\n\n[SPEA"
        let ending = Completeness.ending(of: cutInLabel, within: text)
        #expect(ending.endsInsideSpeakerLabel)
        #expect(ending.kind == .wholeWord)
        #expect(ending.episodeOffset == 49_993)
        #expect(Completeness.verdict(for: ending) == .cut)

        // Against an episode text whose revision moved the cut away from the
        // cap, the unclosed label alone says the transcript was cut.
        let earlier = try #require(text.range(
            of: "\n\n[SPEAKER_",
            range: text.index(text.startIndex, offsetBy: 30_000)..<text.endIndex
        ))
        let cutEarlier = String(text[..<text.index(earlier.lowerBound, offsetBy: 4)])
        #expect(cutEarlier.hasSuffix("\n\n[S"))
        let earlierEnding = Completeness.ending(of: cutEarlier, within: text)
        #expect(earlierEnding.kind == .wholeWord)
        #expect(earlierEnding.episodeOffset.map { $0 < Completeness.retiredImportCap - Completeness.capWindow } == true)
        #expect(earlierEnding.endsInsideSpeakerLabel)
        #expect(Completeness.verdict(for: earlierEnding) == .cut)

        // A label that is closed is the transcript's structure, not a cut,
        // and a bracket inside a line of speech is not a label.
        #expect(Completeness.unclosedTrailingSpeakerLabel(in: "Word1 word2.\n\n[SPEAKER_2]\n") == nil)
        #expect(Completeness.unclosedTrailingSpeakerLabel(in: "He said [laughs") == nil)
        #expect(Completeness.unclosedTrailingSpeakerLabel(in: "Word1 word2.\n\n[") != nil)
    }

    @Test("Where an ending recurs, the earliest place the transcript can reach is taken")
    func repeatedAnchor() {
        // A sponsor read heard mid-episode and again at the very end. A
        // transcript the cap cut right after the first read must not be placed
        // at the second, where it would look complete.
        let read = "Today's episode is brought to you by the same sponsor as always, so stay tuned for the rest."
        let opening = Self.prefix(Self.longEpisode, 49_850)
        let capped = opening + " " + read
        #expect((49_900...50_000).contains(capped.count))
        let episodeText = capped + " " + Self.episode(turns: 20, firstWord: 20_000) + " " + read
        let ending = Completeness.ending(of: capped, within: episodeText)
        #expect(ending.kind == .wholeWord)
        #expect(ending.episodeOffset == capped.count - 1)
        #expect(Completeness.verdict(for: ending) == .cut)
    }

    @Test("A transcript whose ending is not in the episode text is left unplaced")
    func unplaced() {
        let other = Self.episode(turns: 3, firstWord: 900_000)
        #expect(Completeness.verdict(transcript: other, episodeText: Self.longEpisode) == .unplaced)
        // Too few words to place at all.
        #expect(Completeness.verdict(transcript: "Word1 Word2 Word3.", episodeText: Self.longEpisode) == .unplaced)
        #expect(Completeness.verdict(transcript: "", episodeText: Self.longEpisode) == .unplaced)
    }

    @Test("A soft hyphen splits no word")
    func softHyphensAreTransparent() {
        // Hyphenation points in every one of the last thirteen words: read as
        // breaks, no anchor would match and the transcript could not be placed.
        var words = Self.longEpisode.components(separatedBy: " ")
        for index in (words.count - 13)..<words.count {
            words[index] = String(words[index].prefix(3)) + "\u{AD}" + String(words[index].dropFirst(3))
        }
        let hyphenated = words.joined(separator: " ")
        #expect(hyphenated.contains("\u{AD}"))
        #expect(Completeness.verdict(transcript: hyphenated, episodeText: Self.longEpisode) == .complete)
    }

    @Test("The cap's window is closed at both ends, and needs text after it")
    func capWindowBoundaries() {
        func ending(_ offset: Int, after: Int = 40, episode: Int = 60_000, kind: Completeness.Ending.Kind = .wholeWord) -> Completeness.Ending {
            Completeness.Ending(kind: kind, episodeOffset: offset, wordsAfter: after, endsInsideSpeakerLabel: false, episodeCharacterCount: episode)
        }
        let cap = Completeness.retiredImportCap
        #expect(Completeness.verdict(for: ending(cap)) == .cut)
        #expect(Completeness.verdict(for: ending(cap - Completeness.capWindow)) == .cut)
        #expect(Completeness.verdict(for: ending(cap - Completeness.capWindow - 1)) == .complete)
        #expect(Completeness.verdict(for: ending(cap + 1)) == .complete)
        // Nothing after the stop: whatever the place, nothing is missing.
        #expect(Completeness.verdict(for: ending(cap, after: 0)) == .complete)
        #expect(Completeness.verdict(for: ending(30_000, after: 0, kind: .midWord)) == .complete)
        // An episode no longer than the cap was never cut by it.
        #expect(Completeness.verdict(for: ending(49_950, episode: cap)) == .complete)
        // Inside a word is cut wherever it falls.
        #expect(Completeness.verdict(for: ending(30_000, kind: .midWord)) == .cut)
        #expect(Completeness.verdict(for: Completeness.Ending(
            kind: .unplaced, episodeOffset: nil, wordsAfter: 0, endsInsideSpeakerLabel: true, episodeCharacterCount: 60_000
        )) == .unplaced)
    }
}
