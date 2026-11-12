import Foundation

/// Where a stored podcast transcript stops inside the episode text its Apple
/// TTML holds, and whether that stop is the retired 50,000-character import cap.
///
/// Stored transcripts imported by an earlier `SourceService.extractTextFromTTMLContent`
/// hold only the first 50,000 characters of an episode. Counting a transcript
/// as complete when it holds 85% of the TTML text would pass every episode of
/// 50,000 to 58,800 characters with its last sixth missing. Length cannot separate the two cases that matter: speaker
/// names and paragraph breaks push a capped transcript past 50,000, and the
/// ad pass takes a closing sponsor read or outro off a complete one. Where the
/// transcript stops can. The transcript's last words are found in the episode
/// text, and the place they end there says which case it is:
/// - a capped transcript stops at character 49,984 to 50,000 of the episode
///   text, often partway through a word, with the rest of the episode after it;
/// - a complete transcript stops at the episode's end, or, when the ad pass
///   removed a closing read, after a whole word somewhere well before the cap.
///
/// This measures structure, not meaning, so it is deterministic code. It never
/// decides that a transcript it cannot place is cut.
enum PodcastTranscriptCompleteness {

    /// The retired import cap, in characters of the TTML-extracted text, as
    /// `String.prefix` counted them.
    static let retiredImportCap = 50_000

    /// How far below the cap a capped transcript's last whole word can end.
    /// The cap cut wherever it fell, so the stored text stops inside the last
    /// word, or after the word before it, or after a speaker label the cap cut
    /// short; every capped episode measured on a real library (67 of them)
    /// stopped at character 49,984 to 50,000.
    static let capWindow = 100

    /// How many of the transcript's words before its last are looked up in
    /// the episode text, longest first. Twelve words almost never recur in
    /// one episode; the shorter anchors place a transcript whose last words a
    /// paragraph break or a speaker name interrupted.
    static let anchorLengths = [12, 8, 6]

    /// Fewer words than this cannot be placed: the anchor would be most of
    /// the transcript.
    static let minimumPlaceableWords = 7

    struct Ending: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            /// The words before the transcript's last one are the episode's
            /// last words: the transcript runs to the episode's end, or a word
            /// past it.
            case atEnd
            /// The transcript stops after a whole word of the episode.
            case wholeWord
            /// The transcript stops partway through a word of the episode.
            case midWord
            /// The transcript's last word is not the episode's word at the place
            /// its preceding words end.
            case divergent
            /// The transcript's last words are not in the episode text, or the
            /// transcript is too short to place.
            case unplaced
        }

        let kind: Kind
        /// Characters of the episode text up to where the transcript stops;
        /// nil when it could not be placed.
        let episodeOffset: Int?
        /// Words of the episode text after that point, counting a word the
        /// transcript stops inside.
        let wordsAfter: Int
        /// The transcript's last line is a speaker label with no closing
        /// bracket (`[SPEAK`): the cap fell inside the label.
        let endsInsideSpeakerLabel: Bool
        /// Characters in the episode text.
        let episodeCharacterCount: Int
    }

    enum Verdict: Equatable, Sendable {
        /// The transcript holds the episode, or stops early at a place the cap
        /// could not have put it.
        case complete
        /// The transcript stops where the retired cap cut episodes, with more
        /// of the episode after it.
        case cut
        /// The transcript's ending is not in the episode text, so nothing can
        /// be said; it is left as it is.
        case unplaced
    }

    /// Whether `transcript` is the whole episode `episodeText` holds.
    static func verdict(transcript: String, episodeText: String) -> Verdict {
        verdict(for: ending(of: transcript, within: episodeText))
    }

    static func verdict(for ending: Ending) -> Verdict {
        guard ending.kind != .unplaced, let offset = ending.episodeOffset else { return .unplaced }
        guard ending.wordsAfter > 0 else { return .complete }
        let atRetiredCap = ending.episodeCharacterCount > retiredImportCap
            && (retiredImportCap - capWindow)...retiredImportCap ~= offset
        if ending.kind == .midWord || atRetiredCap || ending.endsInsideSpeakerLabel {
            return .cut
        }
        return .complete
    }

    /// Where `transcript` stops inside `episodeText`.
    ///
    /// The last word is held apart, since the cap may have cut it, and the
    /// words before it are looked up in the episode text. Of the places they
    /// occur, the earliest one the transcript can reach is taken: the
    /// transcript is the episode with words removed (ads, labels) and never
    /// with words added, so its words cannot sit before the episode has had as
    /// many, give or take a speaker label's spelling (2% and five words).
    static func ending(of transcript: String, within episodeText: String) -> Ending {
        let trailingLabel = unclosedTrailingSpeakerLabel(in: transcript)
        let stored = words(in: transcript, blanking: trailingLabel.map { [$0] } ?? [])
        let episode = words(in: episodeText, blanking: [])
        func unplaced() -> Ending {
            Ending(
                kind: .unplaced,
                episodeOffset: nil,
                wordsAfter: 0,
                endsInsideSpeakerLabel: trailingLabel != nil,
                episodeCharacterCount: episode.characterCount
            )
        }
        guard stored.words.count >= minimumPlaceableWords, let last = stored.words.last?.text else {
            return unplaced()
        }
        let episodeWords = episode.words
        for length in anchorLengths where stored.words.count >= length + 1 {
            let anchor = stored.words[(stored.words.count - length - 1)..<(stored.words.count - 1)].map(\.text)
            guard let lastIndex = firstReachableIndex(
                after: anchor,
                in: episodeWords,
                storedWordCount: stored.words.count
            ) else { continue }
            guard lastIndex < episodeWords.count else {
                return Ending(
                    kind: .atEnd,
                    episodeOffset: episode.characterCount,
                    wordsAfter: 0,
                    endsInsideSpeakerLabel: trailingLabel != nil,
                    episodeCharacterCount: episode.characterCount
                )
            }
            let word = episodeWords[lastIndex]
            if word.text == last {
                return Ending(
                    kind: .wholeWord,
                    episodeOffset: word.end,
                    wordsAfter: episodeWords.count - lastIndex - 1,
                    endsInsideSpeakerLabel: trailingLabel != nil,
                    episodeCharacterCount: episode.characterCount
                )
            }
            if word.text.hasPrefix(last) {
                return Ending(
                    kind: .midWord,
                    episodeOffset: word.start + last.count,
                    wordsAfter: episodeWords.count - lastIndex,
                    endsInsideSpeakerLabel: trailingLabel != nil,
                    episodeCharacterCount: episode.characterCount
                )
            }
            return Ending(
                kind: .divergent,
                episodeOffset: word.start,
                wordsAfter: episodeWords.count - lastIndex,
                endsInsideSpeakerLabel: trailingLabel != nil,
                episodeCharacterCount: episode.characterCount
            )
        }
        return unplaced()
    }

    // MARK: - Words

    struct Word: Equatable, Sendable {
        /// Lowercased letters and digits.
        let text: String
        /// Character offsets in the text the word was read from.
        let start: Int
        let end: Int
    }

    /// The index in `episodeWords` of the word that follows the earliest
    /// reachable occurrence of `anchor`, or nil when there is none.
    private static func firstReachableIndex(
        after anchor: [String],
        in episodeWords: [Word],
        storedWordCount: Int
    ) -> Int? {
        guard let first = anchor.first, episodeWords.count >= anchor.count else { return nil }
        for start in 0...(episodeWords.count - anchor.count) where episodeWords[start].text == first {
            let following = start + anchor.count
            // The episode must have had about as many words as the transcript
            // holds by the place the transcript's last word sits.
            guard Double(storedWordCount) <= Double(following + 1) * 1.02 + 5 else { continue }
            var matches = true
            for offset in 1..<anchor.count where episodeWords[start + offset].text != anchor[offset] {
                matches = false
                break
            }
            if matches { return following }
        }
        return nil
    }

    /// A speaker label line (`[SPEAKER_1]`, `[Richard Nuccitelli]`) and a
    /// formatted speaker marker (`**Richard:**`) are the transcript's
    /// structure rather than the episode's words; formatting renames and
    /// adds them, so neither text's words include them.
    private static let speakerLabelLine = try! NSRegularExpression(
        pattern: #"^[ \t]*\[[^\]\n]{1,80}\][ \t]*$"#,
        options: [.anchorsMatchLines]
    )
    private static let speakerMarker = try! NSRegularExpression(
        pattern: #"\*\*[^*\n]{1,80}:\*\*"#
    )
    /// A last line that opens a speaker label and never closes it.
    private static let unclosedTrailingLabel = try! NSRegularExpression(
        pattern: #"(?:^|\n)[ \t]*(\[[^\]\n]{0,80})\s*\z"#
    )

    static func unclosedTrailingSpeakerLabel(in text: String) -> Range<String.Index>? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = unclosedTrailingLabel.firstMatch(in: text, range: range),
              let label = Range(match.range(at: 1), in: text) else { return nil }
        return label
    }

    /// The words of `text`: maximal runs of letters and digits, lowercased,
    /// with their character offsets. Speaker labels and markers, and the
    /// `blanking` ranges, are read as spaces. A soft hyphen (U+00AD) is read
    /// as nothing, so a word a soft hyphen splits is one word.
    static func words(
        in text: String,
        blanking extra: [Range<String.Index>]
    ) -> (words: [Word], characterCount: Int) {
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        var blanked = extra
        for expression in [speakerLabelLine, speakerMarker] {
            for match in expression.matches(in: text, range: whole) {
                if let range = Range(match.range, in: text) { blanked.append(range) }
            }
        }
        blanked.sort { $0.lowerBound < $1.lowerBound }

        var words: [Word] = []
        words.reserveCapacity(text.utf8.count / 6)
        var current = ""
        var currentStart = 0
        var currentEnd = 0
        var offset = 0
        var blankIndex = 0
        func close() {
            guard !current.isEmpty else { return }
            words.append(Word(text: current.lowercased(), start: currentStart, end: currentEnd))
            current = ""
        }
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            while blankIndex < blanked.count, blanked[blankIndex].upperBound <= index {
                blankIndex += 1
            }
            let isBlanked = blankIndex < blanked.count && blanked[blankIndex].contains(index)
            if isBlanked {
                close()
            } else if character == "\u{AD}" {
                // Transparent: neither a letter nor a break.
            } else if character.isLetter || character.isNumber {
                if current.isEmpty { currentStart = offset }
                current.append(character)
                currentEnd = offset + 1
            } else {
                close()
            }
            offset += 1
            index = text.index(after: index)
        }
        close()
        return (words, offset)
    }
}
