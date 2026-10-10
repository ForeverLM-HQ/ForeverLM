import AppKit
import Foundation

/// Which rendered block of a transcript a paragraph text view shows: one
/// speaker turn's heading, or the paragraph of its body that starts at
/// `sourceUTF16Offset` in `PodcastTranscriptSegment.text`.
///
/// Doubles as the scroll anchor id for find and reveal, so the same value names
/// a block whether it is being searched, marked, or scrolled to.
struct TranscriptParagraphKey: Hashable, Sendable {
    let segmentIndex: Int
    let field: TranscriptFindMatch.Field
    let sourceUTF16Offset: Int
}

/// A passage of a transcript in the terms the transcript reader lays out in:
/// the segment, the field, and the UTF-16 range within that field's text.
struct TranscriptPassage: Equatable, Sendable {
    let segmentIndex: Int
    let field: TranscriptFindMatch.Field
    /// In the coordinates of the whole heading or body text, not of the
    /// paragraph slice on screen — slices carry their offset so a view can
    /// translate.
    let rangeInField: NSRange
}

/// Where a saved highlight falls in a transcript, segment by segment.
///
/// A highlight can span paragraphs of one speaker turn; each paragraph view
/// intersects `passage.rangeInField` with the slice it shows and paints only
/// its share.
struct TranscriptHighlightPlacement: Equatable, Sendable {
    let highlightID: String
    let color: SourceHighlightColor
    let passage: TranscriptPassage
}

/// The transcript as one string, so a text-quote anchor made anywhere in it
/// carries context across paragraph and speaker boundaries, and a highlight
/// saved by any other reader (the stored text over MCP, say) is found by its
/// words rather than by a layout only this reader knows.
///
/// Every heading and body text is a piece of the joined string, separated by a
/// blank line. Offsets are UTF-16 throughout, because that is what
/// `NSTextView` and `TranscriptTextLayout` measure in.
struct TranscriptDocumentText: Sendable {
    struct Piece: Equatable, Sendable {
        let segmentIndex: Int
        let field: TranscriptFindMatch.Field
        /// Where this piece's text sits in `joined`.
        let joinedRange: NSRange
    }

    let joined: String
    let pieces: [Piece]

    private static let separator = "\n\n"

    init(segments: [PodcastTranscriptSegment]) {
        var joined = ""
        var pieces: [Piece] = []
        var cursor = 0
        func append(_ text: String, segmentIndex: Int, field: TranscriptFindMatch.Field) {
            guard !text.isEmpty else { return }
            if !joined.isEmpty {
                joined += Self.separator
                cursor += (Self.separator as NSString).length
            }
            let length = (text as NSString).length
            pieces.append(Piece(
                segmentIndex: segmentIndex,
                field: field,
                joinedRange: NSRange(location: cursor, length: length)
            ))
            joined += text
            cursor += length
        }
        for segment in segments {
            if let heading = segment.heading {
                append(heading, segmentIndex: segment.index, field: .heading)
            }
            append(segment.text, segmentIndex: segment.index, field: .body)
        }
        self.joined = joined
        self.pieces = pieces
    }

    /// The anchor for a passage the reader selected in one paragraph, measured
    /// against the whole transcript.
    func anchor(for passage: TranscriptPassage) -> (quote: String, anchor: ReaderTextAnchor)? {
        guard let piece = pieces.first(where: {
            $0.segmentIndex == passage.segmentIndex && $0.field == passage.field
        }) else { return nil }
        let clipped = NSIntersectionRange(
            NSRange(location: 0, length: piece.joinedRange.length),
            passage.rangeInField
        )
        guard clipped.length > 0 else { return nil }
        let joinedRange = NSRange(location: piece.joinedRange.location + clipped.location, length: clipped.length)
        guard let range = Range(joinedRange, in: joined) else { return nil }
        let quote = String(joined[range])
        guard !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (quote, ReaderTextAnchor(text: joined, range: range))
    }

    /// Where a highlight's passage falls, piece by piece — more than one when
    /// it crosses from a heading into the body or spans two speaker turns —
    /// or empty when the passage is no longer in the transcript.
    func passages(for anchor: ReaderTextAnchor) -> [TranscriptPassage] {
        guard let range = anchor.resolve(in: joined) else { return [] }
        return passages(inJoined: NSRange(range, in: joined))
    }

    func passages(inJoined range: NSRange) -> [TranscriptPassage] {
        var result: [TranscriptPassage] = []
        for piece in pieces {
            let overlap = NSIntersectionRange(piece.joinedRange, range)
            guard overlap.length > 0 else { continue }
            result.append(TranscriptPassage(
                segmentIndex: piece.segmentIndex,
                field: piece.field,
                rangeInField: NSRange(
                    location: overlap.location - piece.joinedRange.location,
                    length: overlap.length
                )
            ))
        }
        return result
    }

    /// Every highlight placed against this transcript, keyed by segment index
    /// so a row looks up only its own.
    func placements(for highlights: [SourceHighlight]) -> [Int: [TranscriptHighlightPlacement]] {
        var result: [Int: [TranscriptHighlightPlacement]] = [:]
        for highlight in highlights {
            for passage in passages(for: highlight.anchor) {
                result[passage.segmentIndex, default: []].append(TranscriptHighlightPlacement(
                    highlightID: highlight.id,
                    color: highlight.color,
                    passage: passage
                ))
            }
        }
        return result
    }
}

extension TranscriptHighlightPlacement {
    /// The part of this placement that falls inside one paragraph slice, in
    /// the slice's own coordinates. Nil when the highlight does not touch it.
    func localRange(inField field: TranscriptFindMatch.Field, sliceRange: NSRange) -> NSRange? {
        guard passage.field == field else { return nil }
        let overlap = NSIntersectionRange(passage.rangeInField, sliceRange)
        guard overlap.length > 0 else { return nil }
        return NSRange(location: overlap.location - sliceRange.location, length: overlap.length)
    }
}

/// A selection a paragraph text view is reporting, with enough about where it
/// sits for the reader to anchor it.
struct TranscriptParagraphSelection: Equatable {
    let key: TranscriptParagraphKey
    let passage: TranscriptPassage
    let text: String
}

/// One selection and one Chat/Highlight bar for a transcript made of many
/// paragraph text views.
///
/// AppKit lets every `NSTextView` keep a selection of its own; a transcript is
/// one document, so a selection starting in one turn retires the one in
/// another, and the bar follows whichever paragraph holds the live selection.
/// Owned by the reader view, handed to every paragraph it renders.
@MainActor
final class TranscriptSelectionCoordinator {
    /// The selected text, or "" on deselect. Feeds the reader's `selectedText`
    /// binding, which is what ⌘K and the Chat pill act on.
    var selectionChanged: (@MainActor (String) -> Void)?
    /// The reader pressed Highlight over this passage, whose frame on screen
    /// is where the card that follows the mark hangs.
    var highlightRequested: (@MainActor (TranscriptParagraphSelection, _ markOnScreen: CGRect?) -> Void)?
    /// The reader clicked a painted highlight, whose frame on screen is where
    /// its card hangs.
    var openHighlight: (@MainActor (String, _ markOnScreen: CGRect?) -> Void)?
    /// The reader pressed Side chat over this passage, whose frame on screen
    /// the popover hangs off, in the window it was selected in.
    var sideChatRequested: (@MainActor (_ passage: String, _ markOnScreen: CGRect?, _ windowNumber: Int?) -> Void)? {
        didSet { callout.onSideChat = sideChatRequested == nil ? nil : { [weak self] in self?.requestSideChat() } }
    }

    let callout = ReaderSelectionCalloutOverlay()

    private weak var activeTextView: TranscriptParagraphNSTextView?
    /// The selection as it stood when the bar appeared, so pressing Highlight
    /// anchors the passage the reader marked rather than whatever survives the
    /// click.
    private var markedSelection: TranscriptParagraphSelection?
    private var registry: [TranscriptParagraphKey: WeakTextView] = [:]

    private struct WeakTextView {
        weak var view: TranscriptParagraphNSTextView?
    }

    init() {
        callout.onHighlight = { [weak self] in
            guard let self, let marked = self.markedSelection else { return }
            // Where the passage is, read before the selection collapses: the
            // card hangs below it.
            let markOnScreen = self.callout.selectionOnScreen()
            self.callout.hide()
            // Collapse the selection: the mark about to be painted is the
            // feedback now, and the passage is already captured.
            if let active = self.activeTextView {
                active.setSelectedRange(NSRange(location: NSMaxRange(active.selectedRange()), length: 0))
            }
            self.highlightRequested?(marked, markOnScreen)
        }
    }

    /// The side chat hangs off the passage, which stays selected, as Chat
    /// leaves it.
    private func requestSideChat() {
        guard let marked = markedSelection else { return }
        let markOnScreen = callout.selectionOnScreen()
        callout.hide()
        sideChatRequested?(marked.text, markOnScreen, activeTextView?.window?.windowNumber)
    }

    func register(_ textView: TranscriptParagraphNSTextView, for key: TranscriptParagraphKey) {
        registry[key] = WeakTextView(view: textView)
    }

    /// Whether a paragraph view is on screen under `key`.
    func hasView(for key: TranscriptParagraphKey) -> Bool {
        registry[key]?.view != nil
    }

    func unregister(_ textView: TranscriptParagraphNSTextView) {
        registry = registry.filter { $0.value.view !== textView && $0.value.view != nil }
        if activeTextView === textView {
            activeTextView = nil
            markedSelection = nil
            callout.hide()
        }
    }

    /// A paragraph's selection changed. Programmatic changes (find, reveal)
    /// are reported too; the caller filters those before it gets here.
    func selectionDidChange(in textView: TranscriptParagraphNSTextView) {
        let range = textView.selectedRange()
        guard range.length > 0, let selection = textView.selection(for: range) else {
            if activeTextView === textView || activeTextView == nil {
                activeTextView = nil
                markedSelection = nil
                selectionChanged?("")
                callout.hide()
            }
            return
        }
        if let previous = activeTextView, previous !== textView {
            previous.setSelectedRange(NSRange(location: 0, length: 0))
        }
        activeTextView = textView
        markedSelection = selection
        selectionChanged?(selection.text)
        attachCallout(to: textView)
        callout.refresh()
    }

    /// Scrolls the reader's view of a saved highlight into view and selects
    /// it, once the row is on screen.
    func reveal(sliceKey: TranscriptParagraphKey, localRange: NSRange) {
        guard let textView = registry[sliceKey]?.view else { return }
        activeTextView?.setSelectedRange(NSRange(location: 0, length: 0))
        textView.window?.makeFirstResponder(textView)
        textView.programmaticSelection.whileActive {
            textView.setSelectedRange(localRange)
        }
        textView.showFindIndicator(for: localRange)
    }

    func detach() {
        callout.detach()
        activeTextView = nil
        markedSelection = nil
        registry.removeAll()
    }

    /// The bar is hosted in the scroll view's document, not in the paragraph:
    /// a paragraph is often one line tall, and a bar clamped inside it would
    /// sit on the very words it refers to. In document coordinates it rides
    /// along with the text as the reader scrolls, and clamps to the viewport.
    private func attachCallout(to textView: TranscriptParagraphNSTextView) {
        let container = textView.enclosingScrollView?.documentView ?? textView
        callout.attach(
            to: container,
            selectionRect: { [weak textView, weak container] in
                guard let textView, let container,
                      let rect = textView.selectionBoundingRect() else { return nil }
                return textView.convert(rect, to: container)
            },
            tracksScrolling: false
        )
    }
}
