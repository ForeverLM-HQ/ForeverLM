import SwiftUI
import AppKit
import ImageIO

/// Scroll bookkeeping the transcript mutates from layout callbacks and playback
/// ticks without invalidating SwiftUI. Reference type on purpose: row frames and
/// the scroll offset change every scrolled frame, and writing them into `@State`
/// would re-render the whole transcript continuously. Nothing here is read while
/// rendering — only inside main-thread layout and event handlers deciding
/// whether to auto-scroll, so it needs no isolation of its own.
private final class TranscriptScrollMetrics {
    /// Row frames keyed by segment index, in the scroll *content* coordinate
    /// space, so they stay put while scrolling and change only on relayout.
    var rowFrames: [Int: CGRect] = [:]
    var contentOffsetY: CGFloat = 0
    var viewportHeight: CGFloat = 0
    /// Wall clock of the last playback tick, for detecting play/resume.
    var lastTickAt: Date?
    /// Last playback time already handled, throttling sub-second ticks.
    var lastActiveTime: Double?

    /// Whether the row is entirely inside the viewport; nil before first layout.
    func isFullyVisible(_ index: Int) -> Bool? {
        guard viewportHeight > 0, let frame = rowFrames[index] else { return nil }
        return frame.minY >= contentOffsetY - 0.5
            && frame.maxY <= contentOffsetY + viewportHeight + 0.5
    }
}

/// The video playhead, held outside the transcript's view identity.
///
/// A playing recording publishes its position twice a second. Carrying that
/// position as a stored property of the reader re-ran the reader's body on
/// every tick, and that body is a `ForEach` over every speaker turn — 900 of
/// them for an hour-long meeting (built eagerly then; lazily now, but a body
/// pass still walks the whole list). Measured on a shipped build,
/// `UIResponsivenessMonitor` recorded 1.0s, 1.5s and 3.1s
/// main-thread stalls while a meeting recording played, which is what "I can't
/// hit the X while a video is playing" actually was: the click sat in the queue
/// behind a rebuild rather than being lost by the button.
///
/// Ticks land here instead. `@Observable` scopes each write to the views that
/// read that property: `time` is read only by `TranscriptPlayheadTicker`, and
/// `activeSegmentIndex` only by each row's `TranscriptRowWash`, so the playhead
/// advancing repaints two rectangles instead of rebuilding the document.
@Observable
final class TranscriptPlayhead {
    /// Playback position in seconds; nil when nothing has played yet.
    var time: Double?
    /// The segment under the playhead — the row that carries the wash.
    var activeSegmentIndex: Int?

    init(time: Double? = nil) {
        self.time = time
    }
}

/// Zero-sized view whose only job is to read `playhead.time`, so a tick
/// invalidates this and nothing else. Mounted by any view that needs to act on
/// the playhead but must not re-render when it moves.
struct TranscriptPlayheadTicker: View {
    let playhead: TranscriptPlayhead
    let onTick: (Double?) -> Void

    var body: some View {
        // The read that registers the observation is `playhead.time` in the
        // `onChange` value, evaluated here in this body and nowhere else.
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onChange(of: playhead.time) { _, time in onTick(time) }
    }
}

/// The row under the pointer, held outside the reader's view identity for the
/// same reason as the playhead. As `@State` on the reader, every move of the
/// mouse from one row to the next re-ran the body, and with it every row's
/// `updateNSView` and a fresh `sizeThatFits` of every paragraph.
@Observable
final class TranscriptHoverState {
    var segmentIndex: Int?
}

/// One row's play affordance, isolated like the wash: the pointer moving
/// invalidates these leaves rather than the rows themselves.
private struct TranscriptRowHoverBadge: View {
    let hover: TranscriptHoverState
    let index: Int
    let startTime: String

    var body: some View {
        if hover.segmentIndex == index {
            Label(startTime, systemImage: "play.fill")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.thinMaterial, in: Capsule())
                .allowsHitTesting(false)
        }
    }
}

/// One row's playhead wash, isolated for the same reason: the active row
/// changing invalidates these leaves rather than the rows themselves.
private struct TranscriptRowWash: View {
    let playhead: TranscriptPlayhead?
    let index: Int
    let accent: Color

    var body: some View {
        Rectangle()
            .fill(playhead?.activeSegmentIndex == index ? accent.opacity(0.12) : Color.clear)
    }
}

/// Places extracted slide frames against the transcript segment they belong to.
///
/// Split out of the reader view so the anchoring rules stay unit-testable: the
/// failure mode here is silent (slides bunch up on one row instead of crashing),
/// so it needs coverage rather than a visual check.
enum TranscriptSlideAnchoring {
    /// Indices of the segments whose timestamps agree with document order.
    ///
    /// Transcripts arrive with the occasional mis-transcribed timestamp — one
    /// talk in the library runs 2:38 → 25:40 → 3:05 — and a single stray value
    /// must not anchor slides or shadow the segments around it. Keeping the
    /// longest non-decreasing run of starts discards the outlier itself, where
    /// a running-maximum filter would instead discard every segment after it.
    static func monotonicAnchors(timings: [(start: Double, end: Double)]) -> [Int] {
        let timed = timings.indices.filter { timings[$0].start >= 0 }
        guard timed.count > 1 else { return timed }

        // Patience sorting: `tails[n]` is the smallest start that can end a
        // non-decreasing run of length n + 1, and `tailPositions` records where
        // in `timed` that start sits so the winning run can be walked back.
        var tails: [Double] = []
        var tailPositions: [Int] = []
        var predecessor = [Int](repeating: -1, count: timed.count)

        for (position, index) in timed.enumerated() {
            let start = timings[index].start
            var low = 0
            var high = tails.count
            while low < high {
                let mid = (low + high) / 2
                if tails[mid] <= start { low = mid + 1 } else { high = mid }
            }
            predecessor[position] = low > 0 ? tailPositions[low - 1] : -1
            if low == tails.count {
                tails.append(start)
                tailPositions.append(position)
            } else {
                tails[low] = start
                tailPositions[low] = position
            }
        }

        var run: [Int] = []
        var cursor = tailPositions.last ?? -1
        while cursor >= 0 {
            run.append(timed[cursor])
            cursor = predecessor[cursor]
        }
        return run.reversed()
    }

    /// Slides grouped under the last trustworthy segment starting at or before them.
    static func group(
        slides: [YouTubeSlideFrameContext],
        timings: [(start: Double, end: Double)]
    ) -> [Int: [YouTubeSlideFrameContext]] {
        guard !slides.isEmpty else { return [:] }
        let anchors = monotonicAnchors(timings: timings)
        guard let firstAnchor = anchors.first else { return [:] }

        var result: [Int: [YouTubeSlideFrameContext]] = [:]
        for slide in slides {
            guard let time = slide.timeSeconds else { continue }
            var target: Int?
            // Non-decreasing by construction, so the first anchor past the
            // slide ends the search.
            for index in anchors {
                if timings[index].start <= time + 0.25 { target = index } else { break }
            }
            result[target ?? firstAnchor, default: []].append(slide)
        }
        return result
    }

    /// The trustworthy timed segment which owns the playhead.
    ///
    /// Several formatted YouTube paragraphs can sit between two timestamped
    /// paragraphs. Their placeholder timing ranges may overlap the next real
    /// timestamp (for example, 11:29 gets a 30-second fallback even though the
    /// next marker is 11:49). Searching ranges from the top then leaves the old
    /// paragraph active past 11:49. Prefer the latest real marker at or just
    /// before the playhead, then use its end only to reject a genuine gap.
    static func activeSegmentIndex(
        at time: Double,
        timings: [(start: Double, end: Double)]
    ) -> Int? {
        let tolerance = 0.25
        guard let index = monotonicAnchors(timings: timings).last(where: {
            timings[$0].start <= time + tolerance
        }) else {
            return nil
        }
        return time < timings[index].end ? index : nil
    }

    /// A piece of a rendered transcript segment: a run of body text, or a slide dropped into
    /// the flow at the point it came on screen.
    enum SegmentItem: Equatable {
        case text(String, sourceUTF16Offset: Int)
        case slide(YouTubeSlideFrameContext)
    }

    /// Threads a segment's slides into its body text at the point each came on screen.
    ///
    /// `group` above decides *which* segment a slide belongs to; this decides *where inside
    /// it*. The slide's time is interpolated across the segment's spoken span and dropped at
    /// the nearest sentence break, so a slide whose moment lands halfway through a paragraph
    /// does not jump up to the paragraph's first word — the single largest source of the
    /// slide-to-speech drift, since a segment runs 15–30s. Slides with no usable time (or a
    /// segment with no timing) stack ahead of the text.
    static func interleaveSlides(
        into text: String,
        slides: [YouTubeSlideFrameContext],
        segmentStart: Double,
        segmentEnd: Double
    ) -> [SegmentItem] {
        guard !slides.isEmpty else {
            return text.isEmpty ? [] : [.text(text, sourceUTF16Offset: 0)]
        }
        let ordered = slides.sorted { ($0.timeSeconds ?? -1, $0.index) < ($1.timeSeconds ?? -1, $1.index) }
        let ranges = sentenceRanges(in: text)

        // Characters before each sentence boundary, indexed 0...ranges.count.
        var offsets: [Int] = [0]
        for range in ranges {
            offsets.append(offsets[offsets.count - 1] + text.distance(from: range.lowerBound, to: range.upperBound))
        }
        let total = offsets[offsets.count - 1]
        let span = segmentEnd - segmentStart

        func insertionIndex(for slide: YouTubeSlideFrameContext) -> Int {
            guard let time = slide.timeSeconds, span > 0, total > 0 else { return 0 }
            let fraction = min(max((time - segmentStart) / span, 0), 1)
            let target = fraction * Double(total)
            var best = 0
            var bestDistance = Double.greatestFiniteMagnitude
            for (index, offset) in offsets.enumerated() {
                let distance = abs(Double(offset) - target)
                if distance < bestDistance {
                    bestDistance = distance
                    best = index
                }
            }
            return best
        }

        var slidesByBoundary: [Int: [YouTubeSlideFrameContext]] = [:]
        for slide in ordered {
            slidesByBoundary[insertionIndex(for: slide), default: []].append(slide)
        }

        var items: [SegmentItem] = []
        var pending = ""
        var pendingStartOffset = 0
        var consumedUTF16Length = 0
        func flushText() {
            guard !pending.isEmpty else { return }
            items.append(.text(pending, sourceUTF16Offset: pendingStartOffset))
            pending = ""
        }
        for boundary in 0...ranges.count {
            if let group = slidesByBoundary[boundary] {
                flushText()
                for slide in group { items.append(.slide(slide)) }
            }
            if boundary < ranges.count {
                let sentence = String(text[ranges[boundary]])
                if pending.isEmpty {
                    pendingStartOffset = consumedUTF16Length
                }
                pending += sentence
                consumedUTF16Length += (sentence as NSString).length
            }
        }
        flushText()
        return items
    }

    /// Character ranges of the sentences in `text`, split after sentence-ending punctuation.
    /// Trailing whitespace stays on the sentence it follows, so concatenating the ranges
    /// reproduces the original text exactly.
    private static func sentenceRanges(in text: String) -> [Range<String.Index>] {
        guard !text.isEmpty else { return [] }
        guard let regex = try? NSRegularExpression(pattern: #"[.!?]["')\]]?\s+"#) else {
            return [text.startIndex..<text.endIndex]
        }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var boundaries: [String.Index] = []
        regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            if let match, let range = Range(match.range, in: text) {
                boundaries.append(range.upperBound)
            }
        }

        var ranges: [Range<String.Index>] = []
        var start = text.startIndex
        for boundary in boundaries where boundary > start {
            ranges.append(start..<boundary)
            start = boundary
        }
        if start < text.endIndex {
            ranges.append(start..<text.endIndex)
        }
        return ranges.isEmpty ? [text.startIndex..<text.endIndex] : ranges
    }
}

struct TranscriptTextSlice: Equatable, Sendable {
    let text: String
    let sourceUTF16Range: NSRange
}

/// Retains source offsets while splitting transcript text for display. Find uses
/// those offsets to scroll to the paragraph containing the exact occurrence,
/// instead of merely centering a potentially enormous speaker turn.
enum TranscriptTextLayout {
    private static let paragraphSeparator = try! NSRegularExpression(
        pattern: #"(?:\r\n|\r|\n)[\t ]*(?:\r\n|\r|\n)+"#
    )

    static func paragraphSlices(in text: String, sourceUTF16Offset: Int = 0) -> [TranscriptTextSlice] {
        let source = text as NSString
        guard source.length > 0 else { return [] }

        let separators = paragraphSeparator.matches(
            in: text,
            range: NSRange(location: 0, length: source.length)
        )
        var result: [TranscriptTextSlice] = []
        var start = 0

        for separator in separators {
            appendTrimmedSlice(
                from: source,
                range: NSRange(location: start, length: separator.range.location - start),
                sourceUTF16Offset: sourceUTF16Offset,
                to: &result
            )
            start = separator.range.location + separator.range.length
        }
        appendTrimmedSlice(
            from: source,
            range: NSRange(location: start, length: source.length - start),
            sourceUTF16Offset: sourceUTF16Offset,
            to: &result
        )

        return result.isEmpty
            ? [TranscriptTextSlice(
                text: text,
                sourceUTF16Range: NSRange(location: sourceUTF16Offset, length: source.length)
            )]
            : result
    }

    private static func appendTrimmedSlice(
        from source: NSString,
        range: NSRange,
        sourceUTF16Offset: Int,
        to result: inout [TranscriptTextSlice]
    ) {
        guard range.length > 0 else { return }
        let content = CharacterSet.whitespacesAndNewlines.inverted
        let first = source.rangeOfCharacter(from: content, options: [], range: range)
        guard first.location != NSNotFound else { return }
        let last = source.rangeOfCharacter(from: content, options: .backwards, range: range)
        let trimmed = NSRange(
            location: first.location,
            length: last.location + last.length - first.location
        )
        result.append(TranscriptTextSlice(
            text: source.substring(with: trimmed),
            sourceUTF16Range: NSRange(
                location: sourceUTF16Offset + trimmed.location,
                length: trimmed.length
            )
        ))
    }
}

struct TranscriptFindMatch: Equatable, Hashable, Sendable {
    enum Field: Hashable, Sendable {
        case heading
        case body
    }

    let segmentIndex: Int
    let field: Field
    let location: Int
    let length: Int
    let anchorLocation: Int

    var range: NSRange { NSRange(location: location, length: length) }
}

/// Exact, occurrence-level transcript search. This is deliberately independent
/// of SwiftUI so the potentially long transcript scan can run off-main.
enum TranscriptFindEngine {
    static func matches(in segments: [PodcastTranscriptSegment], query: String) -> [TranscriptFindMatch] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }

        var result: [TranscriptFindMatch] = []
        for segment in segments {
            if let heading = segment.heading {
                appendMatches(
                    in: heading,
                    query: needle,
                    segmentIndex: segment.index,
                    field: .heading,
                    slices: TranscriptTextLayout.paragraphSlices(in: heading),
                    to: &result
                )
            }
            appendMatches(
                in: segment.text,
                query: needle,
                segmentIndex: segment.index,
                field: .body,
                slices: TranscriptTextLayout.paragraphSlices(in: segment.text),
                to: &result
            )
        }
        return result
    }

    static func nextIndex(current: Int, count: Int, backwards: Bool) -> Int? {
        guard count > 0 else { return nil }
        if backwards {
            return current <= 0 ? count - 1 : current - 1
        }
        return (current + 1) % count
    }

    private static func appendMatches(
        in text: String,
        query: String,
        segmentIndex: Int,
        field: TranscriptFindMatch.Field,
        slices: [TranscriptTextSlice],
        to result: inout [TranscriptFindMatch]
    ) {
        let source = text as NSString
        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var searchRange = NSRange(location: 0, length: source.length)

        while searchRange.length > 0 {
            let match = source.range(of: query, options: options, range: searchRange)
            guard match.location != NSNotFound else { break }
            let anchor = field == .heading ? 0 : (slices.first(where: {
                match.location >= $0.sourceUTF16Range.location
                    && match.location < $0.sourceUTF16Range.location + $0.sourceUTF16Range.length
            })?.sourceUTF16Range.location ?? 0)
            result.append(TranscriptFindMatch(
                segmentIndex: segmentIndex,
                field: field,
                location: match.location,
                length: match.length,
                anchorLocation: anchor
            ))

            let nextLocation = match.location + max(match.length, 1)
            guard nextLocation < source.length else { break }
            searchRange = NSRange(location: nextLocation, length: source.length - nextLocation)
        }
    }
}

/// Native SwiftUI transcript reader — replaces WKWebView for podcast/meeting/YouTube segments.
///
/// The playback-follow behavior mirrors Andy Matuschak's talk pages
/// (andymatuschak.org/tat): the current segment carries a soft wash, clicking a
/// segment (or its margin slide) seeks the video there, and auto-scroll is
/// deliberately gentle — it follows only while the reader is already at the
/// playhead and never yanks someone who scrolled elsewhere.
struct NativeTranscriptReaderView: View {
    let article: StudioArticle
    let segments: [PodcastTranscriptSegment]
    let layout: TranscriptDisplayLayout
    let kicker: String
    let metadata: String
    let placeholderLabel: String
    @Binding var selectedText: String
    let findState: ReaderFindState
    let findRevision: Int
    /// Playback bridge for a source whose recording plays in-app; nil for a
    /// transcript with no player behind it. A reference rather than the time
    /// itself so ticks never re-run this body — see `TranscriptPlayhead`.
    let playhead: TranscriptPlayhead?
    let timeSelectionAction: ((Double) -> Void)?
    let navigationTarget: SourceSearchBestMatch?
    let zoomScale: CGFloat
    var readerTheme: ReaderColorTheme = .system
    /// Extracted slide frames shown beside the segments they belong to,
    /// Matuschak-style. Empty for sources without slides (podcasts, meetings).
    var slideFrames: [YouTubeSlideFrameContext] = []
    /// Slide being read for cited papers right now, so only its thumb shows progress.
    var scanningSlideID: Int?
    /// "Find papers on this slide", offered from each slide thumb's context menu.
    var slideScanAction: ((YouTubeSlideFrameContext) -> Void)?
    /// Papers read off this video's slides, listed under the thumb each came from. Empty
    /// for sources with no slides, and for a video whose slides have not been read yet.
    var citedPapers: [VideoCitedPaper] = []
    var citedPaperImportAction: ((VideoCitedPaper) -> Void)?
    var citedPaperDismissAction: ((VideoCitedPaper) -> Void)?
    /// "Find" on a paper that came back with no matching record.
    var citedPaperFindAction: (@MainActor (VideoCitedPaper) async -> Void)?
    /// A meeting session's Transcript/Notes/Chat row was clicked in the sidebar:
    /// scroll to that section of this document. Nil everywhere else.
    var sectionTarget: MeetingSectionReaderTarget?
    /// Called once this view has acted on `sectionTarget` — scrolled to it, or
    /// established that the parsed transcript has nowhere matching to go — so a
    /// spent request is not replayed the next time the reader remounts.
    var sectionTargetHandled: (() -> Void)?
    /// A chat citation named a moment in this source and the source has no
    /// player to seek: scroll to the segment being spoken at that time. Nil for
    /// a reader whose player takes the seek and whose playhead then scrolls.
    var timeTarget: ReaderTimeTarget?
    /// Called once `timeTarget` has been acted on, or found nowhere to go.
    var timeTargetHandled: (() -> Void)?

    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(StudioViewModel.self) private var vm
    /// One selection and one Chat/Highlight bar across every paragraph view.
    @State private var selection = TranscriptSelectionCoordinator()
    /// Saved highlights resolved against the transcript, by segment index.
    @State private var highlightPlacements: [Int: [TranscriptHighlightPlacement]] = [:]
    @State private var findMatches: [TranscriptFindMatch] = []
    @State private var findMatchesBySegment: [Int: [TranscriptFindMatch]] = [:]
    @State private var selectedFindMatchIndex = -1
    @State private var currentFindQuery = ""
    @State private var findTask: Task<Void, Never>?
    @State private var hover = TranscriptHoverState()
    @State private var lastFindRevision = 0
    @State private var lastNavigationKey: String?
    @State private var lastSectionKey: String?
    @State private var lastTimeKey: String?
    @State private var metrics = TranscriptScrollMetrics()

    private static let contentSpace = "nativeTranscriptContent"
    private static let contentMaxWidth: CGFloat = 900
    private static let contentHorizontalPadding: CGFloat = 16
    private static let rowHorizontalPadding: CGFloat = 12
    private static let slideGutterWidth: CGFloat = 200
    private static let slideGutterSpacing: CGFloat = 16
    /// Pane width from which slides move into a margin column beside the text
    /// (below it they flow inline above their segment, like the talk pages do
    /// on narrow windows).
    private static let slideGutterMinPaneWidth: CGFloat = 760
    /// Width an inline slide frame is capped at. The transcript reads at column width; a
    /// frame stretched to match it would tower over the paragraph it belongs to.
    private static let inlineSlideWidth: CGFloat = 360
    private static let inlineSlideSpacing: CGFloat = 14
    /// Bounds on a citation card set beside an inline frame. The floor is the gutter
    /// column's width, the narrowest this card is known to read well at; the ceiling keeps
    /// a two-line title from spreading across a column of its own.
    private static let inlineSidePapersMinWidth: CGFloat = 200
    private static let inlineSidePapersMaxWidth: CGFloat = 280
    /// A gap between playback ticks longer than this means playback (re)started,
    /// which may bring the playhead row back into view once.
    private static let resumeTickGap: TimeInterval = 2.5

    private var fontSize: CGFloat {
        NSFont.systemFontSize * ArticleReaderZoom.clamped(zoomScale)
    }

    private var bodyFont: NSFont {
        NSFont.systemFont(ofSize: fontSize)
    }

    private var headingFont: NSFont {
        NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .title3).pointSize, weight: .semibold)
    }

    /// What the placements were computed from; a change re-resolves them.
    private var highlightsFingerprint: String {
        let marks = vm.highlights(for: article.id)
            .map { "\($0.id)|\($0.color.rawValue)|\($0.updatedAt.timeIntervalSince1970)" }
            .joined(separator: ";")
        return "\(article.id)|\(segments.count)|\(marks)"
    }

    private var speakerIndexes: [String: Int] {
        var result: [String: Int] = [:]
        for segment in segments where result[segment.speakerID] == nil {
            result[segment.speakerID] = result.count
        }
        return result
    }

    /// Whether the speaker column earns its width.
    ///
    /// It does only when there is more than one *named* speaker to tell apart.
    /// One speaker labelled down the whole margin says nothing the reader did
    /// not know by the second row, and `unlabeledSpeaker` is not a speaker at
    /// all — it is the stand-in for a transcript that named none, so counting it
    /// would let a single placeholder hold the column open.
    private var showsSpeakerNames: Bool {
        var seen: Set<String> = []
        for segment in segments where segment.hasNamedSpeaker {
            seen.insert(segment.speakerID)
            if seen.count > 1 { return true }
        }
        return false
    }

    private var segmentTimings: [(start: Double, end: Double)] {
        segments.enumerated().map { offset, segment in
            let start = YouTubeTranscriptTime.seconds(from: segment.startTime) ?? -1
            let end = YouTubeTranscriptTime.seconds(from: segment.endTime)
                ?? YouTubeTranscriptTime.seconds(from: segments[safe: offset + 1]?.startTime)
                ?? (start >= 0 ? start + 30 : -1)
            return (start: start, end: max(end, start + 0.5))
        }
    }

    /// Slides grouped under the last segment that starts at or before them.
    private func slidesBySegment(timings: [(start: Double, end: Double)]) -> [Int: [YouTubeSlideFrameContext]] {
        TranscriptSlideAnchoring.group(slides: slideFrames, timings: timings)
    }

    /// Width for a citation card standing beside an inline slide frame, or nil when the
    /// column cannot hold both and the card belongs under the frame instead.
    ///
    /// An inline frame is capped at `inlineSlideWidth` while the text around it runs the
    /// full column, so on a wide enough pane the space to the right of every frame is blank
    /// margin — which is exactly what a citation card wants, and where it keeps the frame
    /// and the paragraph it interrupts closer together than stacking it underneath does.
    static func inlineSidePapersWidth(textColumnWidth: CGFloat) -> CGFloat? {
        let remaining = textColumnWidth - inlineSlideWidth - inlineSlideSpacing
        guard remaining >= inlineSidePapersMinWidth else { return nil }
        return min(remaining, inlineSidePapersMaxWidth)
    }

    /// Width the transcript body actually gets, which is what decides whether a slide's
    /// citations fit beside its frame.
    ///
    /// Derived from the pane rather than measured: measuring would mean writing a
    /// layout-time width back into `@State` on a view that re-renders on every playback
    /// tick. The subtractions mirror the paddings and speaker column below, and a couple of
    /// points either way only nudges where the card changes sides.
    private func textColumnWidth(paneWidth: CGFloat, showsSpeakerNames: Bool) -> CGFloat {
        var width = min(paneWidth, Self.contentMaxWidth)
            - 2 * Self.contentHorizontalPadding
            - 2 * Self.rowHorizontalPadding
        if layout == .speakerTurns {
            // The speaker block — rule, its spacing, and the fixed name/timestamp column —
            // plus the gap between that block and the body.
            width -= showsSpeakerNames ? 3 + 8 + 100 + 16 : 46 + 12
        }
        return width
    }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                let timings = segmentTimings
                let rowSlides = slidesBySegment(timings: timings)
                let showsGutter = !rowSlides.isEmpty && geo.size.width >= Self.slideGutterMinPaneWidth
                // Walks the segments, so it is resolved once here rather than per row.
                let showsSpeakerNames = self.showsSpeakerNames
                // Resolved once per pass and threaded down, rather than recomputed by every
                // row: this body re-runs on each playback tick.
                let slidePapers = VideoCitedPaperWindow.bySlide(papers: citedPapers, slides: slideFrames)
                // Nil in the gutter layout, where 200pt of margin has no room beside a frame.
                let inlinePapersWidth = showsGutter ? nil : Self.inlineSidePapersWidth(
                    textColumnWidth: textColumnWidth(
                        paneWidth: geo.size.width,
                        showsSpeakerNames: showsSpeakerNames
                    )
                )
                let selectedFindMatch = findMatches[safe: selectedFindMatchIndex]

                ScrollView {
                    // Lazy, so only the turns on screen exist. An hour-long meeting is
                    // ~900 turns, each with a seekable timestamp Button, and SwiftUI's
                    // accessibility focus walk visits every live control on each
                    // update: built eagerly, the frame that replaced "Preparing
                    // transcript…" with the rows held the main thread 5.8 s (build 302,
                    // 2026-11-17, every sample in `AccessibilityNode.updateFocus`).
                    LazyVStack(alignment: .leading, spacing: 0) {
                        header
                            .padding(.horizontal, 12)
                            .padding(.bottom, 20)

                        ForEach(segments, id: \.index) { segment in
                            segmentRow(
                                segment,
                                timing: timings[safe: segment.index],
                                slides: rowSlides[segment.index] ?? [],
                                slidePapers: slidePapers,
                                showsGutter: showsGutter,
                                showsSpeakerNames: showsSpeakerNames,
                                inlinePapersWidth: inlinePapersWidth,
                                findMatches: findMatchesBySegment[segment.index] ?? [],
                                selectedFindMatch: selectedFindMatch,
                                highlights: highlightPlacements[segment.index] ?? []
                            )
                            .id(segment.index)
                            .onGeometryChange(for: CGRect.self) { proxy in
                                proxy.frame(in: .named(Self.contentSpace))
                            } action: { frame in
                                metrics.rowFrames[segment.index] = frame
                            }
                            // A row the lazy stack let go of is off screen; its last
                            // frame may be stale once rows above are measured, and
                            // no frame reads as "not known", which the follow rule
                            // treats as "not in view".
                            .onDisappear {
                                metrics.rowFrames[segment.index] = nil
                            }
                        }
                    }
                    .padding(.horizontal, Self.contentHorizontalPadding)
                    .padding(.vertical, 24)
                    .frame(maxWidth: showsGutter
                        ? Self.contentMaxWidth + Self.slideGutterWidth + Self.slideGutterSpacing
                        : Self.contentMaxWidth)
                    .frame(maxWidth: .infinity)
                    .coordinateSpace(.named(Self.contentSpace))
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        -proxy.frame(in: .scrollView).minY
                    } action: { offset in
                        metrics.contentOffsetY = offset
                    }
                }
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    metrics.viewportHeight = height
                }
                .background(readerTheme.readerBackgroundColor)
                // Text colors must resolve against the theme, not the app appearance,
                // or a dark app renders white text onto the light reader background.
                .environment(\.colorScheme, readerTheme.colorSchemeOverride ?? systemColorScheme)
                .onChange(of: findRevision) { _, revision in
                    performFind(revision: revision, scrollProxy: proxy)
                }
                .onChange(of: findState.query) { _, query in
                    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
                    if normalized != currentFindQuery {
                        resetFindResults()
                    }
                }
                .onChange(of: navigationTarget?.presentationKey) { _, _ in
                    navigateToTarget(scrollProxy: proxy)
                }
                .onChange(of: sectionTarget?.presentationKey) { _, _ in
                    navigateToSection(scrollProxy: proxy)
                }
                .onChange(of: timeTarget?.presentationKey) { _, _ in
                    navigateToTime(scrollProxy: proxy)
                }
                .onReceive(NotificationCenter.default.publisher(for: .revealReaderHighlight)) { notification in
                    guard let request = notification.object as? ReaderHighlightRevealRequest,
                          request.sourceID == article.id else { return }
                    revealHighlight(id: request.highlightID, scrollProxy: proxy)
                }
                .task(id: highlightsFingerprint) {
                    await resolveHighlightPlacements()
                }
                // A deck captured on the other Mac reaches this one as a listing
                // only (`SlideFrameRestorer`): its frames are taken again here, and
                // each thumb reads its file once it is written.
                .task(id: "\(article.id):\(slideFrames.count)") {
                    guard !slideFrames.isEmpty else { return }
                    await SlideFrameRestorer.shared.restore(slideFrames, of: article, storage: vm.storage)
                }
                // A section request usually arrives while the document is still
                // parsing — a meeting transcript is often a hundred kilobytes —
                // so the first attempt has no segments to scroll to. Retry when
                // they land rather than dropping the click.
                .onChange(of: segments.count) { _, _ in
                    configureSelectionCoordinator()
                    navigateToSection(scrollProxy: proxy)
                    navigateToTime(scrollProxy: proxy)
                }
                // Mounted rather than an `onChange` on this view: reading the
                // playhead here would put every tick back through this body.
                .background {
                    if let playhead {
                        TranscriptPlayheadTicker(playhead: playhead) { time in
                            updateActiveSegment(for: time, scrollProxy: proxy)
                        }
                    }
                }
                .onAppear {
                    configureSelectionCoordinator()
                    // Playhead first, navigation second, so an explicit search
                    // target wins over restoring the playback position — and a
                    // clicked section, the most explicit request of the three,
                    // last.
                    updateActiveSegment(for: playhead?.time, scrollProxy: proxy)
                    navigateToTarget(scrollProxy: proxy)
                    navigateToSection(scrollProxy: proxy)
                    navigateToTime(scrollProxy: proxy)
                }
                .onChange(of: article.id) {
                    selection.detach()
                    highlightPlacements = [:]
                    configureSelectionCoordinator()
                    playhead?.activeSegmentIndex = nil
                    lastSectionKey = nil
                    lastTimeKey = nil
                    resetFindResults()
                    hover.segmentIndex = nil
                    metrics.rowFrames.removeAll()
                    metrics.lastActiveTime = nil
                    metrics.lastTickAt = nil
                }
                .onDisappear {
                    findTask?.cancel()
                    selection.detach()
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            artwork
            VStack(alignment: .leading, spacing: 4) {
                Text(kicker.uppercased())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(article.title)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(metadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let artwork = article.artworkURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !artwork.isEmpty,
           let url = URL(string: artwork) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    placeholderArtwork
                }
            }
            .frame(width: 74, height: 74)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            placeholderArtwork
        }
    }

    private var placeholderArtwork: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.secondary.opacity(0.12))
            .frame(width: 74, height: 74)
            .overlay {
                Text(placeholderLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
    }

    @ViewBuilder
    private func segmentRow(
        _ segment: PodcastTranscriptSegment,
        timing: (start: Double, end: Double)?,
        slides: [YouTubeSlideFrameContext],
        slidePapers: [Int: [VideoCitedPaper]],
        showsGutter: Bool,
        showsSpeakerNames: Bool,
        inlinePapersWidth: CGFloat?,
        findMatches: [TranscriptFindMatch],
        selectedFindMatch: TranscriptFindMatch?,
        highlights: [TranscriptHighlightPlacement]
    ) -> some View {
        let accent = accentColor(for: segment.speakerID)
        let startSeconds = timing?.start ?? -1
        let seekable = timeSelectionAction != nil && startSeconds >= 0

        HStack(alignment: .top, spacing: Self.slideGutterSpacing) {
            Group {
                if layout == .speakerTurns {
                    HStack(alignment: .top, spacing: showsSpeakerNames ? 16 : 12) {
                        HStack(alignment: .top, spacing: showsSpeakerNames ? 8 : 0) {
                            // The rule is the speaker's color, so it is drawn only
                            // when there are speakers to tell apart. With one voice
                            // it is 11pt of margin encoding nothing; the active row
                            // is already marked by its wash.
                            if showsSpeakerNames {
                                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                    .fill(accent)
                                    .frame(width: 3)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                // Never the placeholder: a transcript that named no
                                // speaker has none to print, and printing the
                                // stand-in fills the margin with one repeated word.
                                if showsSpeakerNames, segment.hasNamedSpeaker {
                                    Text(segment.speakerLabel)
                                        .font(.subheadline.weight(.semibold))
                                }
                                if let startTime = segment.startTime {
                                    timeButton(startTime, seekable: seekable)
                                }
                            }
                            // Fixed either way, so body text keeps one left edge down
                            // the page. Without names it only has to fit a timestamp,
                            // including an hour-long talk's "1:02:10".
                            .frame(width: showsSpeakerNames ? 100 : 46, alignment: .leading)
                        }
                        segmentBody(
                            segment,
                            inlineSlides: showsGutter ? [] : slides,
                            timing: timing,
                            slidePapers: slidePapers,
                            inlinePapersWidth: inlinePapersWidth,
                            findMatches: findMatches,
                            selectedFindMatch: selectedFindMatch,
                            highlights: highlights,
                            seekable: seekable,
                            startSeconds: startSeconds
                        )
                    }
                } else {
                    segmentBody(
                        segment,
                        inlineSlides: showsGutter ? [] : slides,
                        timing: timing,
                        slidePapers: slidePapers,
                        inlinePapersWidth: inlinePapersWidth,
                        findMatches: findMatches,
                        selectedFindMatch: selectedFindMatch,
                        highlights: highlights,
                        seekable: seekable,
                        startSeconds: startSeconds
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Hovering reveals where a click will take the video, the way the
            // talk pages reveal a play affordance per paragraph.
            .overlay(alignment: .topTrailing) {
                if seekable, let startTime = segment.startTime {
                    TranscriptRowHoverBadge(hover: hover, index: segment.index, startTime: startTime)
                }
            }

            if showsGutter {
                slideGutterColumn(slides, slidePapers: slidePapers)
            }
        }
        .padding(.vertical, 14)
        // Constant padding: the wash appears behind the text without reflowing it.
        .padding(.horizontal, Self.rowHorizontalPadding)
        .background {
            TranscriptRowWash(playhead: playhead, index: segment.index, accent: accent)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                hover.segmentIndex = segment.index
            } else if hover.segmentIndex == segment.index {
                hover.segmentIndex = nil
            }
        }
        .onTapGesture {
            guard seekable, startSeconds >= 0 else { return }
            timeSelectionAction?(startSeconds)
        }
    }

    @ViewBuilder
    private func segmentBody(
        _ segment: PodcastTranscriptSegment,
        inlineSlides: [YouTubeSlideFrameContext],
        timing: (start: Double, end: Double)?,
        slidePapers: [Int: [VideoCitedPaper]],
        inlinePapersWidth: CGFloat?,
        findMatches: [TranscriptFindMatch],
        selectedFindMatch: TranscriptFindMatch?,
        highlights: [TranscriptHighlightPlacement],
        seekable: Bool,
        startSeconds: Double
    ) -> some View {
        let placement: SlideCitationPlacement = inlinePapersWidth
            .map { .besideInline(papersWidth: $0) } ?? .belowInline
        // A slide sits at the point in the spoken text where it came on screen, interpolated
        // across the segment's span and dropped at the nearest sentence break, rather than
        // stacked at the paragraph's first word.
        let items = TranscriptSlideAnchoring.interleaveSlides(
            into: segment.text,
            slides: inlineSlides,
            segmentStart: timing?.start ?? -1,
            segmentEnd: timing?.end ?? -1
        )
        // A plain click on a paragraph seeks the recording there, the way a
        // click on the row does; the paragraph views take the click first.
        let seekAction: (() -> Void)? = seekable && startSeconds >= 0
            ? { timeSelectionAction?(startSeconds) }
            : nil
        VStack(alignment: .leading, spacing: 12) {
            if let heading = segment.heading, !heading.isEmpty {
                let key = TranscriptParagraphKey(
                    segmentIndex: segment.index,
                    field: .heading,
                    sourceUTF16Offset: 0
                )
                paragraph(
                    key: key,
                    text: heading,
                    font: headingFont,
                    findMatches: findMatches,
                    selectedFindMatch: selectedFindMatch,
                    highlights: highlights,
                    seekAction: seekAction
                )
                .id(key)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                switch item {
                case .text(let body, let sourceUTF16Offset):
                    let paragraphs = TranscriptTextLayout.paragraphSlices(
                        in: body,
                        sourceUTF16Offset: sourceUTF16Offset
                    )
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, slice in
                        let key = TranscriptParagraphKey(
                            segmentIndex: segment.index,
                            field: .body,
                            sourceUTF16Offset: slice.sourceUTF16Range.location
                        )
                        paragraph(
                            key: key,
                            text: slice.text,
                            font: bodyFont,
                            findMatches: findMatches,
                            selectedFindMatch: selectedFindMatch,
                            highlights: highlights,
                            seekAction: seekAction
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(key)
                    }
                case .slide(let slide):
                    slideThumb(
                        slide,
                        papers: slidePapers[slide.index] ?? [],
                        placement: placement
                    )
                }
            }
        }
    }

    private func slideGutterColumn(
        _ slides: [YouTubeSlideFrameContext],
        slidePapers: [Int: [VideoCitedPaper]]
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(slides) { slide in
                slideThumb(slide, papers: slidePapers[slide.index] ?? [], placement: .gutter)
            }
        }
        .frame(width: Self.slideGutterWidth, alignment: .top)
    }

    /// Where a slide's citation card sits relative to the frame it was read off.
    private enum SlideCitationPlacement {
        /// Under the frame, filling the margin gutter — 200pt of margin has no room beside it.
        case gutter
        /// Under the frame, both at the inline frame's width: the reading column is too
        /// narrow to stand a legible card next to one.
        case belowInline
        /// Beside the frame, in the blank a capped inline frame leaves in the column.
        case besideInline(papersWidth: CGFloat)
    }

    /// A slide frame with the papers it cites, so the citation sits against the frame it was
    /// read off rather than only in a list elsewhere.
    @ViewBuilder
    private func slideThumb(
        _ slide: YouTubeSlideFrameContext,
        papers: [VideoCitedPaper],
        placement: SlideCitationPlacement
    ) -> some View {
        switch placement {
        case .gutter:
            stackedSlide(slide, papers: papers)
        case .belowInline:
            stackedSlide(slide, papers: papers)
                .frame(maxWidth: Self.inlineSlideWidth, alignment: .leading)
        case let .besideInline(papersWidth):
            HStack(alignment: .top, spacing: Self.inlineSlideSpacing) {
                slideFrame(slide)
                    .frame(width: Self.inlineSlideWidth)
                if !papers.isEmpty {
                    citationCard(papers)
                        .frame(width: papersWidth)
                }
            }
        }
    }

    private func stackedSlide(
        _ slide: YouTubeSlideFrameContext,
        papers: [VideoCitedPaper]
    ) -> some View {
        // Tighter than the 8pt this stack sits in, so the card below reads as belonging to the
        // frame above it rather than to the transcript paragraph that follows.
        VStack(alignment: .leading, spacing: 6) {
            slideFrame(slide)
            // Explicitly conditional so a slide with no papers leaves the margin exactly as
            // it was, with no stack spacing held open under the frame.
            if !papers.isEmpty {
                citationCard(papers)
            }
        }
    }

    private func slideFrame(_ slide: YouTubeSlideFrameContext) -> some View {
        SlideMarginThumb(
            slide: slide,
            seekAction: timeSelectionAction,
            scanningSlideID: scanningSlideID,
            scanAction: slideScanAction
        )
    }

    private func citationCard(_ papers: [VideoCitedPaper]) -> some View {
        SlideCitedPapersColumn(
            papers: papers,
            onImport: citedPaperImportAction,
            onDismiss: citedPaperDismissAction,
            onFind: citedPaperFindAction
        )
    }

    /// One selectable paragraph. Every paragraph of the transcript shares the
    /// reader's selection coordinator, so there is one selection and one bar.
    private func paragraph(
        key: TranscriptParagraphKey,
        text: String,
        font: NSFont,
        findMatches: [TranscriptFindMatch],
        selectedFindMatch: TranscriptFindMatch?,
        highlights: [TranscriptHighlightPlacement],
        seekAction: (() -> Void)?
    ) -> some View {
        TranscriptParagraphTextView(
            key: key,
            text: text,
            font: font,
            lineSpacing: 4,
            appearance: readerTheme.nsAppearanceOverride,
            findState: findState,
            findMatches: findMatches,
            selectedFindMatch: selectedFindMatch,
            highlights: highlights,
            selection: selection,
            seekAction: seekAction
        )
    }

    // MARK: Highlights

    /// Points the shared coordinator at this source: selections feed ⇧⌘K and
    /// the Chat pill, Highlight anchors the passage against the whole
    /// transcript, and a click on a mark opens its card.
    private func configureSelectionCoordinator() {
        let sourceID = article.id
        let segments = segments
        let vm = vm
        selection.selectionChanged = { text in
            selectedText = text
        }
        selection.highlightRequested = { paragraphSelection, markOnScreen in
            Task { @MainActor in
                // The anchor is measured against the joined transcript, which
                // for a long meeting is a few hundred kilobytes — off-main.
                let anchored = await Task.detached(priority: .userInitiated) {
                    TranscriptDocumentText(segments: segments).anchor(for: paragraphSelection.passage)
                }.value
                guard let anchored else { return }
                await vm.highlightReaderSelection(
                    sourceID: sourceID,
                    quote: anchored.quote,
                    anchor: anchored.anchor,
                    pdfAnchor: nil,
                    markOnScreen: markOnScreen
                )
            }
        }
        selection.openHighlight = { highlightID, markOnScreen in
            vm.openReaderHighlight(highlightID: highlightID, sourceID: sourceID, markOnScreen: markOnScreen)
        }
        selection.sideChatRequested = { passage, markOnScreen, windowNumber in
            vm.openReaderSideChat(
                sourceID: sourceID,
                passage: passage,
                markOnScreen: markOnScreen,
                windowNumber: windowNumber
            )
        }
    }

    /// Resolves every saved highlight against the transcript, off the main
    /// actor, and hands each row its share.
    private func resolveHighlightPlacements() async {
        let highlights = vm.highlights(for: article.id)
        let segments = segments
        guard !highlights.isEmpty, !segments.isEmpty else {
            highlightPlacements = [:]
            return
        }
        let placements = await Task.detached(priority: .userInitiated) {
            TranscriptDocumentText(segments: segments).placements(for: highlights)
        }.value
        guard !Task.isCancelled else { return }
        highlightPlacements = placements
    }

    /// Scrolls a saved highlight into view and selects it — the notes list's
    /// "reveal", in the transcript's own terms.
    private func revealHighlight(id: String, scrollProxy: ScrollViewProxy) {
        guard let placement = highlightPlacements.values.joined().first(where: { $0.highlightID == id }),
              let segment = segments.first(where: { $0.index == placement.passage.segmentIndex }) else { return }
        let field = placement.passage.field
        let fieldText = field == .heading ? (segment.heading ?? "") : segment.text
        let slices = TranscriptTextLayout.paragraphSlices(in: fieldText)
        let start = placement.passage.rangeInField.location
        guard let slice = slices.first(where: { NSLocationInRange(start, $0.sourceUTF16Range) }) ?? slices.first,
              let localRange = placement.localRange(inField: field, sliceRange: slice.sourceUTF16Range) else {
            return
        }
        let key = TranscriptParagraphKey(
            segmentIndex: segment.index,
            field: field,
            sourceUTF16Offset: slice.sourceUTF16Range.location
        )
        withAnimation(.easeInOut(duration: 0.2)) {
            // A segment whose slides split its paragraphs differently has no
            // view under this key; its row is still the right place to land.
            if selection.hasView(for: key) {
                scrollProxy.scrollTo(key, anchor: .center)
            } else {
                scrollProxy.scrollTo(segment.index, anchor: .center)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            selection.reveal(sliceKey: key, localRange: localRange)
        }
    }

    @ViewBuilder
    private func timeButton(_ startTime: String, seekable: Bool) -> some View {
        if seekable, let seconds = YouTubeTranscriptTime.seconds(from: startTime) {
            Button(startTime) {
                timeSelectionAction?(seconds)
            }
            .buttonStyle(.hoverWash)
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            Text(startTime)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func accentColor(for speakerID: String) -> Color {
        let palette: [Color] = [
            Color(red: 0.18, green: 0.50, blue: 0.93),
            Color(red: 0.76, green: 0.25, blue: 0.48),
            Color(red: 0.13, green: 0.53, blue: 0.48),
            Color(red: 0.71, green: 0.37, blue: 0.02),
            Color(red: 0.43, green: 0.36, blue: 0.82),
            Color(red: 0.42, green: 0.48, blue: 0.0),
        ]
        let index = speakerIndexes[speakerID, default: 0] % palette.count
        return palette[index]
    }

    private func performFind(revision: Int, scrollProxy: ScrollViewProxy) {
        guard revision > 0, revision != lastFindRevision else { return }
        lastFindRevision = revision
        let query = findState.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            resetFindResults()
            return
        }

        if query == currentFindQuery, !findMatches.isEmpty,
           let next = TranscriptFindEngine.nextIndex(
               current: selectedFindMatchIndex,
               count: findMatches.count,
               backwards: findState.searchesBackward
           ) {
            selectFindMatch(at: next, scrollProxy: scrollProxy)
            return
        }

        findTask?.cancel()
        currentFindQuery = query
        findMatches = []
        findMatchesBySegment = [:]
        selectedFindMatchIndex = -1
        findState.statusText = "Searching…"
        let snapshot = segments
        let backwards = findState.searchesBackward
        findTask = Task { @MainActor in
            let matches = await Task.detached(priority: .userInitiated) {
                TranscriptFindEngine.matches(in: snapshot, query: query)
            }.value
            guard !Task.isCancelled,
                  revision == lastFindRevision,
                  query == currentFindQuery else { return }
            findMatches = matches
            findMatchesBySegment = Dictionary(grouping: matches, by: \.segmentIndex)
            guard !matches.isEmpty else {
                findState.statusText = "No matches"
                return
            }
            selectFindMatch(at: backwards ? matches.count - 1 : 0, scrollProxy: scrollProxy)
        }
    }

    private func selectFindMatch(at index: Int, scrollProxy: ScrollViewProxy) {
        guard let match = findMatches[safe: index] else { return }
        selectedFindMatchIndex = index
        findState.statusText = "\(index + 1) of \(findMatches.count)"
        let target = TranscriptParagraphKey(
            segmentIndex: match.segmentIndex,
            field: match.field,
            sourceUTF16Offset: match.anchorLocation
        )
        // The paragraph's id exists only once its row is built, and the column
        // is lazy: land on the row first, then on the paragraph inside it.
        if selection.hasView(for: target) {
            withAnimation(.easeInOut(duration: 0.2)) {
                scrollProxy.scrollTo(target, anchor: .center)
            }
        } else {
            scrollProxy.scrollTo(match.segmentIndex, anchor: .top)
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.2)) {
                    scrollProxy.scrollTo(target, anchor: .center)
                }
            }
        }
    }

    private func resetFindResults() {
        findTask?.cancel()
        findTask = nil
        currentFindQuery = ""
        findMatches = []
        findMatchesBySegment = [:]
        selectedFindMatchIndex = -1
    }

    private func navigateToTarget(scrollProxy: ScrollViewProxy) {
        guard let target = navigationTarget,
              lastNavigationKey != target.presentationKey else { return }
        lastNavigationKey = target.presentationKey
        let query = target.findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        for segment in segments {
            if segment.text.range(of: query, options: options) != nil {
                // This is only the immediate fallback while the occurrence-level
                // find below resolves off-main. A podcast can contain one very
                // tall same-speaker turn; centering that whole row makes both its
                // beginning and end disappear and looks like truncated content.
                // Top-aligning keeps the document boundary intelligible until the
                // exact matching paragraph becomes the scroll target.
                scrollProxy.scrollTo(segment.index, anchor: .top)
                return
            }
        }
    }

    /// Scroll to the section a sidebar artifact row asked for: the paragraph
    /// under the matching `## Transcript` / `## Notes` / `## Chat` heading.
    ///
    /// Three ways to find it, because the merged document is written by whoever
    /// wrote the Doc. Normally the section's first paragraph carries the section
    /// heading as its own; a section that opens with a heading of its own is
    /// found by that heading instead; and failing both, by the text of the first
    /// paragraph the view model captured.
    private func navigateToSection(scrollProxy: ScrollViewProxy) {
        guard let target = sectionTarget,
              target.sourceID == article.id,
              lastSectionKey != target.presentationKey,
              !segments.isEmpty else { return }
        lastSectionKey = target.presentationKey
        defer { sectionTargetHandled?() }

        // The section heading, then the heading the section itself opens with.
        for label in [target.kind.label, target.subheading].compactMap({ $0 }) {
            guard let headed = segments.first(where: {
                $0.heading?.caseInsensitiveCompare(label) == .orderedSame
            }) else { continue }
            withAnimation(.easeInOut(duration: 0.2)) {
                scrollProxy.scrollTo(headed.index, anchor: .top)
            }
            return
        }

        // Segment text has been through the parser's own cleanup, so the anchor
        // gets the same treatment before it is looked for; otherwise a line the
        // Doc wrote as "word ." would never be found in the "word." the reader
        // renders.
        let anchor = Self.parserCleanedText(target.anchorText ?? "")
        guard !anchor.isEmpty else { return }
        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        guard let matched = segments.first(where: {
            $0.text.range(of: anchor, options: options) != nil
        }) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            scrollProxy.scrollTo(matched.index, anchor: .top)
        }
    }

    /// Scroll to the segment being spoken at the moment a chat citation named.
    /// The playhead's own rule picks the row — the latest real marker at or
    /// before the time — and a moment past the last marker's span still lands
    /// on the last segment that had started, rather than nowhere.
    private func navigateToTime(scrollProxy: ScrollViewProxy) {
        guard let target = timeTarget,
              target.sourceID == article.id,
              lastTimeKey != target.presentationKey,
              !segments.isEmpty else { return }
        lastTimeKey = target.presentationKey
        defer { timeTargetHandled?() }

        let timings = segmentTimings
        let index = TranscriptSlideAnchoring.activeSegmentIndex(at: target.seconds, timings: timings)
            ?? timings.lastIndex(where: { $0.start >= 0 && $0.start <= target.seconds + 0.25 })
        guard let index, let segment = segments[safe: index] else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            scrollProxy.scrollTo(segment.index, anchor: .top)
        }
    }

    /// `YouTubeTranscriptDisplayParser.cleanText`'s whitespace rules, applied to
    /// text that has to be matched against a parsed segment.
    private static func parserCleanedText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+([.,!?;:%\)])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"([\(\[])\s+"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func updateActiveSegment(for time: Double?, scrollProxy: ScrollViewProxy) {
        guard let time else { return }
        let now = Date()
        let resumed = metrics.lastTickAt.map { now.timeIntervalSince($0) > Self.resumeTickGap } ?? true
        metrics.lastTickAt = now
        if let last = metrics.lastActiveTime, abs(last - time) < 0.35, !resumed { return }
        metrics.lastActiveTime = time

        let timings = segmentTimings
        guard let newIndex = TranscriptSlideAnchoring.activeSegmentIndex(
            at: time,
            timings: timings
        ) else { return }
        let oldIndex = playhead?.activeSegmentIndex
        guard newIndex != oldIndex || resumed else { return }
        playhead?.activeSegmentIndex = newIndex
        scrollForTransition(from: oldIndex, to: newIndex, resumed: resumed, proxy: scrollProxy)
    }

    /// The gentle follow rule from the talk pages: never move if the new row is
    /// already fully in view (including the row the reader just clicked); follow
    /// an adjacent advance only when the reader was at the playhead (old row
    /// fully visible); bring the playhead into view on seeks and play/resume;
    /// and center the playhead row when following. A row taller than the
    /// viewport aligns to the top so its beginning stays readable.
    private func scrollForTransition(from oldIndex: Int?, to newIndex: Int, resumed: Bool, proxy: ScrollViewProxy) {
        if metrics.isFullyVisible(newIndex) == true { return }

        let isAdjacent = oldIndex.map { abs(newIndex - $0) <= 1 } ?? false
        if isAdjacent, !resumed, metrics.isFullyVisible(oldIndex ?? -1) != true {
            return
        }

        guard metrics.isFullyVisible(newIndex) != nil else {
            // No layout information yet (first appearance): fall back to centering.
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(newIndex, anchor: .center)
            }
            return
        }

        let anchor: UnitPoint
        if let frame = metrics.rowFrames[newIndex], frame.height >= metrics.viewportHeight - 8 {
            anchor = .top
        } else {
            anchor = .center
        }
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(newIndex, anchor: anchor)
        }
    }
}

/// Downsampled slide thumbnail beside the transcript; clicking seeks the video
/// to the slide's moment.
struct SlideMarginThumb: View {
    let slide: YouTubeSlideFrameContext
    let seekAction: ((Double) -> Void)?
    /// Slide being read for cited papers anywhere in the transcript: this thumb
    /// shows progress when it is the one, and further scans wait either way.
    var scanningSlideID: Int?
    var scanAction: ((YouTubeSlideFrameContext) -> Void)?

    @State private var image: NSImage?
    @State private var didLoad = false
    @State private var isHovered = false

    private var seekSeconds: Double? {
        guard seekAction != nil else { return nil }
        return slide.timeSeconds
    }

    var body: some View {
        Button {
            if let seekSeconds {
                seekAction?(seekSeconds)
            }
        } label: {
            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.secondary.opacity(didLoad ? 0.06 : 0.1))
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .overlay {
                            if didLoad {
                                Image(systemName: "photo")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.secondary.opacity(isHovered ? 0.45 : 0.18), lineWidth: 1)
            }
            .overlay(alignment: .bottomTrailing) {
                if isHovered, let seconds = slide.timeSeconds {
                    Label(YouTubeTranscriptTime.display(seconds), systemImage: "play.fill")
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.thinMaterial, in: Capsule())
                        .padding(5)
                }
            }
            .overlay {
                if scanningSlideID == slide.id {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.black.opacity(0.3))
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(seekSeconds == nil)
        .onHover { isHovered = $0 && seekSeconds != nil }
        .cursor(seekSeconds != nil ? .pointingHand : .arrow)
        .help(slide.timeSeconds.map { "Jump video to \(YouTubeTranscriptTime.display($0))" } ?? slide.displayTitle)
        .contextMenu {
            if let scanAction {
                Button {
                    scanAction(slide)
                } label: {
                    Label("Find Papers on This Slide", systemImage: "doc.text.magnifyingglass")
                }
                .disabled(scanningSlideID != nil)
            }
        }
        .task(id: slide.imagePath) {
            image = nil
            didLoad = false
            await load()
        }
        // The frame was not on this Mac and has just been captured again.
        .onReceive(NotificationCenter.default.publisher(for: SlideFrameRestorer.framesRestored)) { _ in
            guard image == nil else { return }
            Task { await load() }
        }
    }

    private func load() async {
        let path = slide.imagePath
        // Path resolution can touch iCloud storage helpers and the file may
        // be evicted, so both the URL resolution and the decode stay off-main.
        image = await Task.detached(priority: .utility) {
            Self.loadThumbnail(path: path, maxPixel: 480)
        }.value
        didLoad = true
    }

    /// Decodes a downsampled thumbnail instead of the full frame: full-size
    /// frames for every slide scrolled past would pin tens of megabytes per video.
    nonisolated static func loadThumbnail(path: String, maxPixel: CGFloat) -> NSImage? {
        // Resolve across every known content root, not just the single one that
        // `absoluteSourcePath` prepends. A build without the iCloud entitlement
        // resolves that single root to the non-existent local fallback, so a
        // relative slide-image path has to be tried against all roots the way
        // source files are (via `locateSourceFile`) or the frame renders blank.
        // This stats the filesystem — callers already run it off the main actor.
        let resolvedPath = StorageService.locateSourceFile(path)
            ?? (path.hasPrefix("/") ? path : StorageService.absoluteSourcePath(path))
        let url = URL(fileURLWithPath: resolvedPath)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
    }
}

private extension ReaderColorTheme {
    /// Fixed readers keep their paper tint; system readers match the app canvas.
    var readerBackgroundColor: Color {
        switch self {
        case .light:
            Color(nsColor: NSColor(red: 0.98, green: 0.98, blue: 0.97, alpha: 1))
        case .system:
            Color(nsColor: .textBackgroundColor)
        case .dark:
            Color(nsColor: NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1))
        }
    }
}
