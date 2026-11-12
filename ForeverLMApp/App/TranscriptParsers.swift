import AppKit
import SwiftUI

struct PodcastTranscriptSegment: Equatable, Sendable {
    /// Stand-in label for a segment no speaker was named for. Not a speaker —
    /// readers must not present it as one, or an undiarized transcript ends up
    /// with the same word down its whole margin.
    static let unlabeledSpeaker = "Transcript"

    let index: Int
    let speakerID: String
    let speakerLabel: String
    let startTime: String?
    let endTime: String?
    let text: String
    let heading: String?

    var hasNamedSpeaker: Bool { speakerLabel != Self.unlabeledSpeaker }

    init(
        index: Int,
        speakerID: String,
        speakerLabel: String,
        startTime: String?,
        endTime: String?,
        text: String,
        heading: String? = nil
    ) {
        self.index = index
        self.speakerID = speakerID
        self.speakerLabel = speakerLabel
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.heading = heading
    }
}

enum TranscriptDisplayLayout: Equatable {
    case speakerTurns
    case sections
}

enum PodcastTranscriptParser {
    static func parseTTML(
        _ content: String,
        speakerNameOverrides: [String: String] = [:]
    ) -> [PodcastTranscriptSegment] {
        let paragraphPattern = #"<p\b([^>]*)>(.*?)</p>"#
        guard let paragraphRegex = try? NSRegularExpression(
            pattern: paragraphPattern,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else { return [] }

        let fullRange = NSRange(content.startIndex..<content.endIndex, in: content)
        let matches = paragraphRegex.matches(in: content, range: fullRange)
        var segments: [PodcastTranscriptSegment] = []

        for match in matches {
            guard let attrsRange = Range(match.range(at: 1), in: content),
                  let bodyRange = Range(match.range(at: 2), in: content) else { continue }

            let attrs = String(content[attrsRange])
            let body = String(content[bodyRange])
            let speakerID = attribute("ttm:agent", in: attrs)
                ?? attribute("agent", in: attrs)
                ?? "SPEAKER"
            let text = readableParagraphText(extractText(fromParagraphBody: body))
            guard !text.isEmpty else { continue }

            segments.append(PodcastTranscriptSegment(
                index: segments.count,
                speakerID: speakerID,
                speakerLabel: speakerNameOverrides[speakerID] ?? displayName(for: speakerID),
                startTime: displayTime(attribute("begin", in: attrs)),
                endTime: displayTime(attribute("end", in: attrs)),
                text: text
            ))
        }

        return mergeAdjacentSegments(segments)
    }

    private static func mergeAdjacentSegments(_ segments: [PodcastTranscriptSegment]) -> [PodcastTranscriptSegment] {
        var merged: [PodcastTranscriptSegment] = []

        for segment in segments {
            guard let previous = merged.last, previous.speakerID == segment.speakerID else {
                merged.append(segment)
                continue
            }

            merged[merged.count - 1] = PodcastTranscriptSegment(
                index: previous.index,
                speakerID: previous.speakerID,
                speakerLabel: previous.speakerLabel,
                startTime: previous.startTime,
                endTime: segment.endTime ?? previous.endTime,
                text: mergedTranscriptText(previous.text, appending: segment.text),
                heading: previous.heading
            )
        }

        return merged.enumerated().map { offset, segment in
            PodcastTranscriptSegment(
                index: offset,
                speakerID: segment.speakerID,
                speakerLabel: segment.speakerLabel,
                startTime: segment.startTime,
                endTime: segment.endTime,
                text: segment.text,
                heading: segment.heading
            )
        }
    }

    /// The same paragraphs a podcast transcript saved before formatting is
    /// stored with, so an episode reads alike here and on every other device.
    private static func readableParagraphText(_ text: String) -> String {
        StudioViewModel.readableTranscriptParagraphs(text)
    }

    private static func mergedTranscriptText(_ existing: String, appending next: String) -> String {
        let trimmedNext = next.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNext.isEmpty else { return existing }
        guard !existing.isEmpty else { return trimmedNext }

        if existing.contains("\n\n") || trimmedNext.contains("\n\n") {
            return existing + "\n\n" + trimmedNext
        }

        let previousWords = wordCount(lastParagraph(in: existing))
        let nextWords = wordCount(trimmedNext)
        if previousWords >= 55 || nextWords >= 65 {
            return existing + "\n\n" + trimmedNext
        }

        return existing + " " + trimmedNext
    }

    private static func lastParagraph(in text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized
            .replacingOccurrences(of: #"\n{2,}"#, with: "\u{0}", options: .regularExpression)
            .components(separatedBy: "\u{0}")
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? normalized
    }

    private static func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace }.count
    }

    private static func attribute(_ name: String, in attrs: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"(?:^|\s)"# + escapedName + #"=(["'])(.*?)\1"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(attrs.startIndex..<attrs.endIndex, in: attrs)
        guard let match = regex.firstMatch(in: attrs, range: range),
              let valueRange = Range(match.range(at: 2), in: attrs) else { return nil }
        return decodeEntities(String(attrs[valueRange]))
    }

    private static func extractText(fromParagraphBody body: String) -> String {
        let wordPattern = #"<span[^>]*podcasts:unit=(["'])word\1[^>]*>(.*?)</span>"#
        if let wordRegex = try? NSRegularExpression(
            pattern: wordPattern,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) {
            let range = NSRange(body.startIndex..<body.endIndex, in: body)
            let words = wordRegex.matches(in: body, range: range).compactMap { match -> String? in
                guard let valueRange = Range(match.range(at: 2), in: body) else { return nil }
                return stripTagsAndDecode(String(body[valueRange]))
            }
            let text = words.joined(separator: " ")
            if !text.isEmpty {
                return cleanSpacing(text)
            }
        }

        return cleanSpacing(stripTagsAndDecode(body))
    }

    private static func stripTagsAndDecode(_ value: String) -> String {
        let stripped = value.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: "",
            options: .regularExpression
        )
        return decodeEntities(stripped)
    }

    private static func cleanSpacing(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s+([.,!?;:%\)])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"([\(\[])\s+"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func displayName(for speakerID: String) -> String {
        let normalized = speakerID.replacingOccurrences(of: "_", with: " ")
        if normalized.uppercased().hasPrefix("SPEAKER") {
            return normalized.capitalized
        }
        return normalized
    }

    private static func displayTime(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasSuffix("s"), let seconds = Double(trimmed.dropLast()) {
            return YouTubeTranscriptTime.display(seconds)
        }

        let parts = trimmed.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty, parts.count <= 3 else { return trimmed }
        let seconds: Double
        if parts.count == 3 {
            seconds = parts[0] * 3600 + parts[1] * 60 + parts[2]
        } else if parts.count == 2 {
            seconds = parts[0] * 60 + parts[1]
        } else {
            seconds = parts[0]
        }
        return YouTubeTranscriptTime.display(seconds)
    }

    private static func decodeEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
    }
}

enum YouTubeTranscriptDisplayParser {
    struct Result {
        let segments: [PodcastTranscriptSegment]
        let layout: TranscriptDisplayLayout
    }

    /// One block, split but not yet committed: whether the speaker reading is
    /// used at all depends on how the rest of the transcript read.
    private struct ParsedBlock {
        let heading: String?
        let time: String?
        let speaker: String?
        /// Body with the speaker prefix taken off…
        let labeledText: String
        /// …and with it left in place, for when the reading is rejected. A
        /// rejected label must go back into the sentence it was cut from.
        let rawText: String
    }

    static func parse(_ content: String) -> Result {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return Result(segments: [], layout: .sections)
        }

        var pendingHeading: String?
        var parsedBlocks: [ParsedBlock] = []

        for block in transcriptBlocks(from: normalized) {
            let headingParse = parseLeadingHeading(from: block)
            if let heading = headingParse.heading {
                pendingHeading = heading
            }
            guard !headingParse.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            let timeParse = parseLeadingTime(from: headingParse.text)
            let rawText = cleanText(timeParse.text)
            guard !rawText.isEmpty else { continue }

            parsedBlocks.append(ParsedBlock(
                heading: pendingHeading,
                time: timeParse.time,
                speaker: nil,
                labeledText: rawText,
                rawText: rawText
            ))
            pendingHeading = nil
        }

        var segments: [PodcastTranscriptSegment] = []
        // The label is the same for every block; fold it once, not once per row.
        let label = PodcastTranscriptSegment.unlabeledSpeaker
        let speakerID = stableSpeakerID(label)
        for block in parsedBlocks {
            segments.append(PodcastTranscriptSegment(
                index: segments.count,
                speakerID: speakerID,
                speakerLabel: label,
                startTime: block.time,
                endTime: nil,
                text: block.rawText,
                heading: block.heading
            ))
        }

        return Result(
            segments: segments,
            layout: .sections
        )
    }

    private static func transcriptBlocks(from text: String) -> [String] {
        let sectionAware = replacing(sectionBreakRegex, in: text, with: "\n\n")
        let paragraphSeparated = replacing(paragraphBreakRegex, in: sectionAware, with: "\u{0}")
            .components(separatedBy: "\u{0}")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if paragraphSeparated.count > 1 {
            return paragraphSeparated
        }

        let wordCount = text.split(separator: " ").count
        guard wordCount > 140 else { return paragraphSeparated }
        return sentenceChunks(from: text)
    }

    private static func sentenceChunks(from text: String) -> [String] {
        let separated = replacing(sentenceBreakRegex, in: text, with: "\u{0}")
        let sentences = separated
            .components(separatedBy: "\u{0}")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard sentences.count > 1 else { return wordChunks(from: text) }

        var chunks: [String] = []
        var current: [String] = []
        var currentWordCount = 0

        for sentence in sentences {
            current.append(sentence)
            currentWordCount += sentence.split(separator: " ").count
            if current.count >= 4 || currentWordCount >= 95 {
                chunks.append(current.joined(separator: " "))
                current = []
                currentWordCount = 0
            }
        }

        if !current.isEmpty {
            chunks.append(current.joined(separator: " "))
        }
        return chunks
    }

    private static func wordChunks(from text: String) -> [String] {
        let words = text.split(separator: " ").map(String.init)
        guard words.count > 140 else { return [text] }

        var chunks: [String] = []
        var current: [String] = []
        for word in words {
            current.append(word)
            if current.count >= 95 {
                chunks.append(current.joined(separator: " "))
                current = []
            }
        }
        if !current.isEmpty {
            chunks.append(current.joined(separator: " "))
        }
        return chunks
    }

    /// `text` is one block of the already line-ending-normalised transcript, so a
    /// plain split on "\n" is the whole job.
    private static func parseLeadingHeading(from text: String) -> (heading: String?, text: String) {
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first else { return (nil, text) }
        // The regex decides; this only spares the bridge to NSString for the
        // overwhelming majority of blocks, which are not headings.
        guard first.first(where: { !$0.isWhitespace }) == "#" else { return (nil, text) }
        guard let match = firstMatch(leadingHeadingRegex, in: first),
              let heading = match.captures.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !heading.isEmpty else {
            return (nil, text)
        }
        let remainder = lines.dropFirst().joined(separator: "\n")
        return (heading, remainder)
    }

    private static func parseLeadingTime(from text: String) -> (time: String?, text: String) {
        // Same bargain as the heading: a block that does not open with a digit or a
        // bracket cannot match, so it never pays for the regex.
        guard let lead = text.first(where: { !$0.isWhitespace }),
              lead == "[" || lead.isNumber else { return (nil, text) }
        guard let match = firstMatch(leadingTimeRegex, in: text),
              let time = match.captures.first,
              let fullRange = Range(match.fullRange, in: text) else {
            return (nil, text)
        }
        let remainder = String(text[fullRange.upperBound...])
        return (time, remainder)
    }

    /// Punctuation that a preceding whitespace run is dropped in front of, and the
    /// brackets a following run is dropped after.
    private static let closingPunctuation: Set<Unicode.Scalar> = [".", ",", "!", "?", ";", ":", "%", ")"]
    private static let openingBrackets: Set<Unicode.Scalar> = ["(", "["]

    /// Collapse every whitespace run to one space, drop the run before closing
    /// punctuation and after an opening bracket, and trim the ends. One pass over
    /// the scalars: a newline replace and three regex replaces would each
    /// bridge the block to NSString, once per block.
    private static func cleanText(_ text: String) -> String {
        var cleaned = String.UnicodeScalarView()
        var pendingWhitespace = false
        var previous: Unicode.Scalar?
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                pendingWhitespace = true
                continue
            }
            if pendingWhitespace {
                pendingWhitespace = false
                if let previous,
                   !closingPunctuation.contains(scalar),
                   !openingBrackets.contains(previous) {
                    cleaned.append(" ")
                }
            }
            cleaned.append(scalar)
            previous = scalar
        }
        return String(cleaned)
    }

    private static func stableSpeakerID(_ label: String) -> String {
        let folded = label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return replacing(nonAlphanumericRunRegex, in: folded, with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            .uppercased()
    }

    private static func displayName(for speakerLabel: String) -> String {
        let normalized = speakerLabel.replacingOccurrences(of: "_", with: " ")
        if normalized.uppercased().hasPrefix("SPEAKER") {
            return normalized.capitalized
        }
        return speakerLabel
    }

    private struct RegexMatch {
        let fullRange: NSRange
        let captures: [String]
    }

    // Compiled once. Building these from their pattern on each call would run
    // the block-level ones once per block: for a Zoom standup of 149
    // turns that is some 750 regex compilations per parse, most of the 8 ms the
    // parse took in the debug test bundle, and 70 ms of a 135 KB
    // Nexus session's. The patterns are constants, so a failed compile is a
    // programming error, not a runtime condition.
    private static let sectionBreakRegex = try! NSRegularExpression(pattern: #"\n(?=#{1,3}\s)"#)
    private static let paragraphBreakRegex = try! NSRegularExpression(pattern: #"\n{2,}"#)
    private static let sentenceBreakRegex = try! NSRegularExpression(pattern: #"(?<=[.!?])\s+"#)
    private static let leadingHeadingRegex = try! NSRegularExpression(pattern: #"^\s*#{1,3}\s+(.+?)\s*$"#)
    private static let leadingTimeRegex = try! NSRegularExpression(pattern: #"^\s*\[?(\d{1,2}:\d{2}(?::\d{2})?)\]?\s+"#)
    private static let nonAlphanumericRunRegex = try! NSRegularExpression(pattern: #"[^A-Za-z0-9]+"#)

    /// `replacingOccurrences(of:with:options: .regularExpression)` with the compile
    /// hoisted out; the template syntax (`$1`) is the same.
    private static func replacing(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> RegexMatch? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        let captures = (1..<match.numberOfRanges).compactMap { index -> String? in
            let captureRange = match.range(at: index)
            guard captureRange.location != NSNotFound,
                  let range = Range(captureRange, in: text) else { return nil }
            return String(text[range])
        }
        return RegexMatch(fullRange: match.range, captures: captures)
    }
}

/// One continuous stretch of the video during which a slide is on screen.
///
/// `end` is open only for content written before ranges existed, whose headings carry a
/// single timestamp; the display layer closes those at the next slide's start.
struct SlideTimeWindow: Equatable, Sendable {
    let start: Double
    let end: Double?
}

/// Sendable is explicit rather than inferred: `scanSlide` hands one of these to the
/// `SlideCitationService` actor, so the conformance is load-bearing at that call.
struct YouTubeSlideFrameContext: Equatable, Identifiable, Sendable {
    let index: Int
    /// When the slide first comes on screen. Drives seeks, margin placement, and the
    /// timestamp on the thumb.
    let timeSeconds: Double?
    /// Every stretch of the video during which this slide is on screen — one window per
    /// appearance, so a page the presenter cuts away from and back to has several. Anything
    /// keyed to the slide (its cited papers, above all) is current exactly inside these.
    let windows: [SlideTimeWindow]
    let imagePath: String
    let recognizedText: String
    /// True when the citation vision pass judged this frame a photograph of the room — a wide
    /// shot of the speaker, a seated panel, the audience — or an otherwise contentless frame,
    /// rather than a deck page. The frame stays in the stored deck (so a misjudgement is
    /// reversible and never deletes a real slide) but is filtered out of what the reader
    /// shows, which is what stops a slide and a camera shot of it appearing twice. Carried in
    /// the stored block as a `Non-slide: true` line — see `YouTubeSlideContentParser`.
    let isNonSlide: Bool

    init(
        index: Int,
        timeSeconds: Double?,
        windows: [SlideTimeWindow],
        imagePath: String,
        recognizedText: String,
        isNonSlide: Bool = false
    ) {
        self.index = index
        self.timeSeconds = timeSeconds
        self.windows = windows
        self.imagePath = imagePath
        self.recognizedText = recognizedText
        self.isNonSlide = isNonSlide
    }

    var id: Int { index }

    var displayTitle: String {
        if let timeSeconds {
            return "Slide \(index) · \(YouTubeTranscriptTime.display(timeSeconds))"
        }
        return "Slide \(index)"
    }

    // Slide images are loaded through `SlideMarginThumb.loadThumbnail(path:)`,
    // which resolves `imagePath` across every known content root off the main
    // actor. A synchronous `imageURL` here could only resolve a single root and
    // would reintroduce the missing-cover class of bug, so it is intentionally
    // absent — resolve via `loadThumbnail`, not a main-thread URL accessor.
}

struct YouTubeSlideContent: Equatable {
    let transcriptContent: String
    let slides: [YouTubeSlideFrameContext]

    /// The slides the reader actually shows: every stored frame except the ones the vision
    /// pass marked as photographs of the room. Filtering here rather than deleting the blocks
    /// keeps the judgement reversible and the cited-paper keying intact.
    ///
    /// If *every* frame is marked — which the write-time guard is meant to prevent, but a
    /// hand-edited deck could still carry — fall back to showing all of them. A
    /// deck that renders empty is the one failure worse than a stray camera shot slipping
    /// through, so the reader never hides the whole thing.
    var displaySlides: [YouTubeSlideFrameContext] {
        let shown = slides.filter { !$0.isNonSlide }
        return shown.isEmpty ? slides : shown
    }
}

enum YouTubeSlideContentParser {
    private static let slideHeader = "## Extracted video slide frames"
    /// The line that marks a stored frame as a photograph of the room rather than a deck page.
    /// Written into the block by the citation vision pass; read back by `parse` into
    /// `isNonSlide`; filtered out of `displaySlides`. A marker rather than a deletion so the
    /// frame is still there to be reclassified, and its cited-paper keying survives.
    static let nonSlideMarker = "Non-slide: true"

    static func parse(_ content: String) -> YouTubeSlideContent {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard let headerRange = normalized.range(of: slideHeader) else {
            return YouTubeSlideContent(transcriptContent: content, slides: [])
        }

        let transcript = String(normalized[..<headerRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let slideMarkdown = String(normalized[headerRange.lowerBound...])
        return YouTubeSlideContent(
            transcriptContent: transcript.isEmpty ? content : transcript,
            slides: parseSlides(from: slideMarkdown)
        )
    }

    private static func parseSlides(from markdown: String) -> [YouTubeSlideFrameContext] {
        let chunks = markdown
            .components(separatedBy: "\n### Slide frame ")
            .dropFirst()

        return chunks.compactMap { rawChunk -> YouTubeSlideFrameContext? in
            let lines = rawChunk
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            guard let heading = lines.first else { return nil }
            let index = parseIndex(from: heading) ?? 0
            guard index > 0 else { return nil }
            let windows = parseWindows(from: heading)

            guard let imageLineIndex = lines.firstIndex(where: { $0.hasPrefix("Image:") }) else {
                return nil
            }
            let imagePath = String(lines[imageLineIndex].dropFirst("Image:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !imagePath.isEmpty else { return nil }

            let isNonSlide = lines.contains { line in
                line.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(nonSlideMarker) == .orderedSame
            }

            let recognizedText: String
            if let textLabelIndex = lines.firstIndex(where: { $0 == "Recognized slide text:" }) {
                recognizedText = lines.dropFirst(textLabelIndex + 1)
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                recognizedText = ""
            }

            return YouTubeSlideFrameContext(
                index: index,
                timeSeconds: windows.first?.start,
                windows: windows,
                imagePath: imagePath,
                recognizedText: recognizedText,
                isNonSlide: isNonSlide
            )
        }
    }

    private static func parseIndex(from heading: String) -> Int? {
        let prefix = heading.prefix { $0.isNumber }
        return Int(prefix)
    }

    /// Reads every bracketed group in a slide heading. `[1:23–2:45]` is one on-screen
    /// window; a bare `[2:05]` is content that recorded a single timestamp, kept as
    /// an open-ended window for the display layer to close at the next slide's start.
    private static func parseWindows(from heading: String) -> [SlideTimeWindow] {
        var windows: [SlideTimeWindow] = []
        var remainder = Substring(heading)
        while let open = remainder.firstIndex(of: "["),
              let close = remainder[open...].firstIndex(of: "]") {
            let group = remainder[remainder.index(after: open)..<close]
            remainder = remainder[remainder.index(after: close)...]

            // Timestamps never contain a hyphen, so either dash splits safely.
            let bounds = group
                .split(whereSeparator: { $0 == "–" || $0 == "-" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if bounds.count == 2,
               let start = YouTubeTranscriptTime.seconds(from: bounds[0]),
               let end = YouTubeTranscriptTime.seconds(from: bounds[1]) {
                windows.append(SlideTimeWindow(start: start, end: max(start, end)))
            } else if bounds.count == 1,
                      let start = YouTubeTranscriptTime.seconds(from: bounds[0]) {
                windows.append(SlideTimeWindow(start: start, end: nil))
            }
        }
        return windows.sorted { $0.start < $1.start }
    }

    /// Marks or unmarks stored frames as photographs of the room, returning the rewritten
    /// content — or `nil` when nothing changed, so a caller can skip a needless write.
    ///
    /// The citation vision pass judges each scanned frame a deck page or a photograph of the
    /// room (a wide shot of the speaker, the audience). Rather than deleting a flagged frame's
    /// block — which permanently loses a real slide the model got wrong, and once wiped a whole
    /// deck when it misjudged every frame — this adds a `Non-slide: true` line to the flagged
    /// blocks and removes it from the ones this same scan judged real. The frame stays in the
    /// stored deck either way; `displaySlides` is what hides it. Blocks are otherwise preserved
    /// verbatim, numbering and all, since cited papers are keyed to the image path.
    ///
    /// `nonSlidePaths` are the frames to mark; `scannedPaths` are every frame this scan looked
    /// at, so a frame it reversed its judgement on has its stale mark cleared. A frame in
    /// neither set — one this scan never reached — is left exactly as it was.
    static func markingNonSlideFrames(
        _ nonSlidePaths: Set<String>,
        clearingAmong scannedPaths: Set<String>,
        in content: String
    ) -> String? {
        guard !nonSlidePaths.isEmpty || !scannedPaths.isEmpty else { return nil }
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard let headerRange = normalized.range(of: slideHeader) else { return nil }

        let head = String(normalized[..<headerRange.lowerBound])
        let section = String(normalized[headerRange.lowerBound...])
        let separator = "\n### Slide frame "
        let parts = section.components(separatedBy: separator)
        guard parts.count > 1 else { return nil }

        let preamble = parts[0]
        var rewrittenBlocks: [String] = []
        var changed = false
        for block in parts.dropFirst() {
            guard let path = imagePath(inSlideBlock: block) else {
                rewrittenBlocks.append(block)
                continue
            }
            let shouldMark = nonSlidePaths.contains(path)
            // Clear a stale mark only on a frame this scan actually re-judged as real; never
            // on one it did not reach, which would silently un-hide a camera shot from an
            // earlier scan.
            let shouldClear = !shouldMark && scannedPaths.contains(path)
            let updated = shouldMark
                ? blockAddingNonSlideMark(block)
                : (shouldClear ? blockRemovingNonSlideMark(block) : block)
            if updated != block { changed = true }
            rewrittenBlocks.append(updated)
        }
        guard changed else { return nil }
        return head + ([preamble] + rewrittenBlocks).joined(separator: separator)
    }

    /// Adds the non-slide marker directly after the block's `Image:` line, once. A block that
    /// already carries it is returned unchanged.
    private static func blockAddingNonSlideMark(_ block: String) -> String {
        var lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(nonSlideMarker) == .orderedSame }),
              let imageLineIndex = lines.firstIndex(where: { $0.hasPrefix("Image:") }) else {
            return block
        }
        lines.insert(nonSlideMarker, at: imageLineIndex + 1)
        return lines.joined(separator: "\n")
    }

    /// Strips any non-slide marker lines from the block.
    private static func blockRemovingNonSlideMark(_ block: String) -> String {
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let kept = lines.filter { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(nonSlideMarker) != .orderedSame }
        return kept.count == lines.count ? block : kept.joined(separator: "\n")
    }

    private static func imagePath(inSlideBlock block: String) -> String? {
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) where line.hasPrefix("Image:") {
            let path = line.dropFirst("Image:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        }
        return nil
    }
}

/// Rewrites a YouTube transcript's section headings to match YouTube's official
/// chapter markers (see `YouTubeTranscriptService.fetchChapters`).
///
/// The reader derives its "Chapters" menu — and its inline section breaks —
/// straight from the `##` headings in the transcript markdown. Rather than
/// teach the whole rendering pipeline about a second chapter source, this swaps
/// the headings themselves: it strips whatever headings the transcript carries
/// (the AI formatter's topic guesses) and re-inserts one heading per official
/// chapter, anchored to the timestamped caption block nearest the chapter's
/// start. Each heading inherits that caption's `[m:ss]`, so `chapters(in:)`
/// then yields the video's real chapters with no change downstream.
///
/// A no-op when `chapters` is empty — callers pass an empty array for a video
/// with no official chapters, which leaves the AI headings in place as the
/// fallback. Idempotent: re-applying the same chapters produces identical text,
/// so an already-migrated transcript compares equal and is never rewritten.
enum YouTubeChapterMarkup {
    static func applyingOfficialChapters(_ chapters: [YouTubeTranscriptService.VideoChapter], to transcript: String) -> String {
        guard !chapters.isEmpty else { return transcript }

        let normalized = transcript
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Blocks are blank-line-separated paragraphs. Strip existing heading
        // lines up front so only the official headings survive.
        var blocks = normalized
            .components(separatedBy: "\n\n")
            .map { stripHeadingLines(from: $0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !blocks.isEmpty else { return transcript }

        // Each block's start time, from its leading [m:ss] marker. Only timed
        // blocks can anchor a chapter.
        let blockStarts = blocks.map { leadingSeconds(in: $0) }
        let timedIndices = blockStarts.indices.filter { blockStarts[$0] != nil }
        guard !timedIndices.isEmpty else { return transcript }

        // Assign each chapter to the nearest timed block, advancing a pointer so
        // assignments stay monotonic and two chapters never land on one block.
        var headingForBlock: [Int: String] = [:]
        var searchStart = 0
        for chapter in chapters {
            guard searchStart < timedIndices.count else { break }
            var bestPosition = searchStart
            var bestDistance = Double.greatestFiniteMagnitude
            for position in searchStart..<timedIndices.count {
                guard let start = blockStarts[timedIndices[position]] else { continue }
                let distance = abs(start - chapter.startSeconds)
                if distance < bestDistance {
                    bestDistance = distance
                    bestPosition = position
                }
                // Blocks are sorted by time, so once we reach the target no later
                // block can be closer.
                if start >= chapter.startSeconds { break }
            }
            let blockIndex = timedIndices[bestPosition]
            if headingForBlock[blockIndex] == nil {
                headingForBlock[blockIndex] = chapter.title
            }
            searchStart = bestPosition + 1
        }
        guard !headingForBlock.isEmpty else { return transcript }

        for (blockIndex, title) in headingForBlock {
            blocks[blockIndex] = "## \(title)\n\(blocks[blockIndex])"
        }
        return blocks.joined(separator: "\n\n")
    }

    private static func stripHeadingLines(from block: String) -> String {
        block
            .components(separatedBy: "\n")
            .filter { $0.range(of: #"^\s{0,3}#{1,6}\s+"#, options: .regularExpression) == nil }
            .joined(separator: "\n")
    }

    private static func leadingSeconds(in block: String) -> Double? {
        guard let firstLine = block.components(separatedBy: "\n").first,
              let range = firstLine.range(of: #"\d{1,2}:\d{2}(?::\d{2})?"#, options: .regularExpression),
              firstLine[..<range.lowerBound].allSatisfy({ $0 == " " || $0 == "[" }) else {
            return nil
        }
        return YouTubeTranscriptTime.seconds(from: String(firstLine[range]))
    }
}

enum YouTubeTranscriptTime {
    static func seconds(from time: String?) -> Double? {
        guard let time else { return nil }
        let parts = time.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        if parts.count == 3 {
            return parts[0] * 3600 + parts[1] * 60 + parts[2]
        }
        if parts.count == 2 {
            return parts[0] * 60 + parts[1]
        }
        return parts[0]
    }

    static func display(_ seconds: Double) -> String {
        MediaClock.reading(seconds)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Parse memo

/// App-lifetime memo for parsed transcript display models, keyed by a cheap
/// content signature. Reader views keep parse results in `@State`, which dies
/// with the view whenever the selection changes, so every re-open re-loaded and
/// re-parsed the same transcript behind a "Preparing transcript…" placeholder —
/// and podcasts re-read their raw TTML from storage each time. Views consult
/// the memo synchronously while rendering (a dictionary lookup, render-safe)
/// and fall back to their off-main parse tasks only on a miss. Deliberately not
/// `@Observable`: storing into it from a render-path memoization must never
/// invalidate views.
@MainActor
final class TranscriptParseMemo<Value> {
    private var entries: [String: Value] = [:]
    private var insertionOrder: [String] = []
    private let limit: Int

    init(limit: Int = 6) {
        self.limit = limit
    }

    subscript(key: String) -> Value? {
        entries[key]
    }

    func store(_ value: Value, for key: String) {
        if entries[key] == nil {
            insertionOrder.append(key)
            if insertionOrder.count > limit {
                entries.removeValue(forKey: insertionOrder.removeFirst())
            }
        }
        entries[key] = value
    }
}

@MainActor
enum TranscriptParseMemos {
    static let youtube = TranscriptParseMemo<(slides: YouTubeSlideContent, transcript: YouTubeTranscriptDisplayParser.Result)>()
    static let podcast = TranscriptParseMemo<[PodcastTranscriptSegment]>()
    /// Fallback rendering of the stored podcast transcript text (no TTML).
    static let storedPodcast = TranscriptParseMemo<YouTubeTranscriptDisplayParser.Result>()
    /// Meetings carry slides in the same stored blob as the transcript, exactly as YouTube
    /// videos do, so the memo holds both halves of the split.
    static let meeting = TranscriptParseMemo<(slides: [YouTubeSlideFrameContext], transcript: YouTubeTranscriptDisplayParser.Result)>()
}
