import AppKit
import SwiftUI

/// One paragraph of a transcript, drawn by an `NSTextView` rather than a
/// SwiftUI `Text`.
///
/// SwiftUI's selectable `Text` lets the reader copy words but tells nobody
/// what was selected, so a podcast or meeting transcript could not be chatted
/// about or marked the way an article or PDF can. An `NSTextView` reports its
/// selection, can be selected into programmatically (find, reveal), and takes
/// background attributes for saved highlights. The view is non-scrolling and
/// sizes itself to its text at the width SwiftUI proposes, so the transcript's
/// own layout — speaker column, slides, playhead wash — is untouched.
final class TranscriptParagraphNSTextView: NSTextView {
    weak var coordinator: TranscriptSelectionCoordinator?
    weak var findState: ReaderFindState?
    var key = TranscriptParagraphKey(segmentIndex: -1, field: .body, sourceUTF16Offset: 0)
    /// The slice this view shows, in its field's coordinates.
    var sliceRange = NSRange(location: 0, length: 0)
    /// A plain click on a transcript whose recording plays in-app seeks there,
    /// the way clicking the row does.
    var seekAction: (() -> Void)?
    /// Painted marks in local coordinates, for click hit-testing.
    var paintedHighlights: [(id: String, range: NSRange)] = []
    /// Set while find or reveal move the selection, so those moves are not
    /// reported as the reader's own.
    let programmaticSelection = ReaderProgrammaticSelection()

    private static let markerAttribute = NSAttributedString.Key("ForeverLMTranscriptHighlight")
    /// Heights by the width they were laid out at, and the size at no width
    /// at all. SwiftUI asks for all of these on every layout pass — a row's
    /// HStack probes each paragraph at zero, unbounded and the real width
    /// before placing it — and only the text or the font changes the answer.
    /// With one cached width each probe would throw
    /// the previous layout away, so one pass would typeset every paragraph of the
    /// transcript four times, once with a character to a line, and a hover or
    /// a find on an hour's talk would wedge the main thread for seconds
    /// (`UIResponsivenessMonitor` samples ending in `ensureLayoutForTextContainer:`).
    private var heightsByWidth: [CGFloat: CGFloat] = [:]
    private var unconstrainedSizeCache: CGSize?
    private var appliedFingerprint = ""
    private var paintedHighlightFingerprint = ""
    private var paintedFindFingerprint = ""
    /// The words a pinch pointed at in this paragraph, waiting for SwiftUI to
    /// lay the transcript out at the new size so they can go back under the
    /// pointer.
    private var pinchAnchor: ReaderPinchTextAnchor?
    /// The view SwiftUI hosts this paragraph in, watched while a pinch
    /// settles. SwiftUI moves a paragraph by moving its host, so a row above
    /// that grew reaches this one only as a change to the host's frame.
    private weak var watchedHost: NSView?

    // MARK: Content

    func apply(text: String, font: NSFont, lineSpacing: CGFloat, textColor: NSColor) {
        let fingerprint = "\(font.fontName)|\(font.pointSize)|\(lineSpacing)|\(text)"
        guard fingerprint != appliedFingerprint, let storage = textStorage else { return }
        appliedFingerprint = fingerprint
        notePinchAnchor()
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        storage.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: font,
            .paragraphStyle: style,
            .foregroundColor: textColor,
        ]))
        typingAttributes = [.font: font, .paragraphStyle: style, .foregroundColor: textColor]
        heightsByWidth.removeAll()
        unconstrainedSizeCache = nil
        // The string is new, so every background attribute went with it.
        paintedHighlightFingerprint = ""
        paintedFindFingerprint = ""
    }

    /// A pinch zooms about the words under the pointer. The new size reaches
    /// this paragraph before SwiftUI lays the transcript out again, which it
    /// does on its own schedule (a few hundred milliseconds later for a long
    /// transcript), after first setting this view's old frame once more. So
    /// until the pinch has settled, the anchor goes back whenever this
    /// paragraph is resized or moved and its frame is the height of its new
    /// text, and once on the next turn of the main queue. Putting it back is
    /// idempotent: once the words are under the pointer, nothing moves.
    private func notePinchAnchor() {
        guard let anchor = ReaderPinchAnchor.textAnchor(in: self) else { return }
        pinchAnchor = anchor
        if watchedHost == nil, let host = superview {
            watchedHost = host
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(hostFrameChanged(_:)),
                name: NSView.frameDidChangeNotification,
                object: host
            )
        }
        DispatchQueue.main.async { [weak self] in
            self?.restorePinchAnchor()
        }
        // Lets go of the host once the pinch has settled, if nothing else
        // came through here after it.
        DispatchQueue.main.asyncAfter(deadline: .now() + ReaderPinchAnchor.settleTime + 0.1) { [weak self] in
            self?.restorePinchAnchor()
        }
    }

    @objc private func hostFrameChanged(_ notification: Notification) {
        restorePinchAnchor()
    }

    private func restorePinchAnchor() {
        guard let pinchAnchor else { return }
        guard pinchAnchor.isSettling else {
            self.pinchAnchor = nil
            if let host = watchedHost {
                NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: host)
                watchedHost = nil
            }
            return
        }
        // Until SwiftUI has given this paragraph the height of its new text,
        // the frame and the text disagree about where the words are.
        guard abs(frame.height - height(forWidth: frame.width)) < 1 else { return }
        pinchAnchor.restore()
    }

    /// Puts a pinch's anchor back on a real resize only. SwiftUI sets
    /// unchanged frames on every re-render (a hover, the playhead), and a
    /// scroll made just after a pinch must stay where the reader put it.
    override func setFrameSize(_ newSize: NSSize) {
        let resized = newSize != frame.size
        super.setFrameSize(newSize)
        if resized { restorePinchAnchor() }
    }

    /// Height of the text laid out at `width`. Cached for every width asked,
    /// not only the last: SwiftUI asks on every layout pass, at several widths
    /// per pass, and the transcript has hundreds of paragraphs.
    func height(forWidth width: CGFloat) -> CGFloat {
        let key = (width * 2).rounded() / 2
        if let cached = heightsByWidth[key] { return cached }
        guard let container = textContainer, let layoutManager else { return 0 }
        container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let height = ceil(layoutManager.usedRect(for: container).height)
        // A pane dragged narrower proposes a new width every frame.
        if heightsByWidth.count >= 64 { heightsByWidth.removeAll() }
        heightsByWidth[key] = height
        return height
    }

    /// Natural size of the text on one line, for a proposal with no width.
    func unconstrainedSize() -> CGSize {
        if let cached = unconstrainedSizeCache { return cached }
        guard let container = textContainer, let layoutManager else { return .zero }
        container.containerSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        let size = CGSize(width: ceil(used.width), height: ceil(used.height))
        unconstrainedSizeCache = size
        return size
    }

    // MARK: Painting

    func paintHighlights(_ marks: [(id: String, color: SourceHighlightColor, range: NSRange)]) {
        let fingerprint = marks.map { "\($0.id)|\($0.color.rawValue)|\($0.range.location)|\($0.range.length)" }.joined(separator: ";")
        guard fingerprint != paintedHighlightFingerprint, let storage = textStorage else { return }
        paintedHighlightFingerprint = fingerprint
        let fullRange = NSRange(location: 0, length: storage.length)
        var previouslyPainted: [NSRange] = []
        storage.enumerateAttribute(Self.markerAttribute, in: fullRange) { value, range, _ in
            if value != nil { previouslyPainted.append(range) }
        }
        storage.beginEditing()
        for range in previouslyPainted {
            storage.removeAttribute(.backgroundColor, range: range)
            storage.removeAttribute(Self.markerAttribute, range: range)
        }
        var painted: [(id: String, range: NSRange)] = []
        for mark in marks {
            let range = NSIntersectionRange(mark.range, fullRange)
            guard range.length > 0 else { continue }
            storage.addAttribute(Self.markerAttribute, value: mark.id, range: range)
            storage.addAttribute(
                .backgroundColor,
                value: ReaderTextViewHighlightSupport.color(for: mark.color),
                range: range
            )
            painted.append((mark.id, range))
        }
        storage.endEditing()
        paintedHighlights = painted
    }

    /// Find matches go on as temporary attributes, so they draw over a saved
    /// mark without disturbing it and come off without a repaint.
    func paintFindMatches(_ matches: [(range: NSRange, color: NSColor)]) {
        let fingerprint = matches.map { "\($0.range.location)|\($0.range.length)|\($0.color.description)" }.joined(separator: ";")
        guard fingerprint != paintedFindFingerprint, let layoutManager, let storage = textStorage else { return }
        paintedFindFingerprint = fingerprint
        let fullRange = NSRange(location: 0, length: storage.length)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
        for match in matches {
            let range = NSIntersectionRange(match.range, fullRange)
            guard range.length > 0 else { continue }
            layoutManager.addTemporaryAttribute(.backgroundColor, value: match.color, forCharacterRange: range)
        }
    }

    // MARK: Selection

    /// The passage `range` of this paragraph names, in the reader's terms.
    func selection(for range: NSRange) -> TranscriptParagraphSelection? {
        let source = string as NSString
        let clipped = NSIntersectionRange(range, NSRange(location: 0, length: source.length))
        guard clipped.length > 0 else { return nil }
        let text = source.substring(with: clipped)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return TranscriptParagraphSelection(
            key: key,
            passage: TranscriptPassage(
                segmentIndex: key.segmentIndex,
                field: key.field,
                rangeInField: NSRange(location: sliceRange.location + clipped.location, length: clipped.length)
            ),
            text: text
        )
    }

    /// The selection's bounds in this view's coordinates, for placing the bar.
    func selectionBoundingRect() -> CGRect? {
        guard let layoutManager, let container = textContainer else { return nil }
        let range = selectedRange()
        guard range.length > 0 else { return nil }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        return rect
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hadSelection = selectedRange().length > 0
        super.mouseDown(with: event)
        // NSTextView tracks the drag inside mouseDown, so a returned call with
        // the button up and nothing selected was a click. A drag that ended
        // with a selection is the coordinator's business, via the delegate.
        guard NSEvent.pressedMouseButtons == 0, selectedRange().length == 0 else { return }
        if let id = highlightID(at: point) {
            coordinator?.openHighlight?(id, paintedMarkFrameOnScreen(id: id))
            return
        }
        // A click that only retired a selection is not a request to seek.
        if !hadSelection { seekAction?() }
    }

    /// This paragraph's share of a painted mark, on screen, for the card that
    /// opens on it. A mark spanning paragraphs anchors on the paragraph that
    /// was clicked; the others are separate views.
    private func paintedMarkFrameOnScreen(id: String) -> CGRect? {
        guard let painted = paintedHighlights.first(where: { $0.id == id }),
              let layoutManager, let container = textContainer else { return nil }
        let range = NSIntersectionRange(painted.range, NSRange(location: 0, length: (string as NSString).length))
        guard range.length > 0 else { return nil }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        guard !rect.isEmpty else { return nil }
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        return screenFrame(of: rect)
    }

    private func highlightID(at point: CGPoint) -> String? {
        guard !paintedHighlights.isEmpty, let layoutManager, let container = textContainer else { return nil }
        let local = CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyphIndex = layoutManager.glyphIndex(for: local, in: container)
        // Past the last character on a line the nearest glyph is reported;
        // only a click on the glyph itself counts as a click on the mark.
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: container)
        guard glyphRect.insetBy(dx: -2, dy: -2).contains(local) else { return nil }
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        return paintedHighlights.first { NSLocationInRange(characterIndex, $0.range) }?.id
    }

    // MARK: Keyboard and gestures

    override func keyDown(with event: NSEvent) {
        if event.isReaderFindShortcut {
            findState?.show()
            return
        }
        super.keyDown(with: event)
    }

    override func magnify(with event: NSEvent) {
        guard let window, ReaderShortcutRouter.shared.magnify(with: event, in: window) else {
            super.magnify(with: event)
            return
        }
    }
}

/// The SwiftUI face of `TranscriptParagraphNSTextView`.
struct TranscriptParagraphTextView: NSViewRepresentable {
    let key: TranscriptParagraphKey
    let text: String
    let font: NSFont
    let lineSpacing: CGFloat
    /// The reader theme's appearance, or nil to follow the window.
    let appearance: NSAppearance?
    let findState: ReaderFindState
    /// This segment's find matches, in field coordinates; the view keeps the
    /// ones that fall in its slice.
    let findMatches: [TranscriptFindMatch]
    let selectedFindMatch: TranscriptFindMatch?
    /// This segment's highlight placements; the view paints its share.
    let highlights: [TranscriptHighlightPlacement]
    let selection: TranscriptSelectionCoordinator
    let seekAction: (() -> Void)?

    private var sliceRange: NSRange {
        NSRange(location: key.sourceUTF16Offset, length: (text as NSString).length)
    }

    func makeCoordinator() -> Delegate {
        Delegate()
    }

    func makeNSView(context: Context) -> TranscriptParagraphNSTextView {
        // TextKit 1: avoids a macOS 26 TextKit 2 hang where click selection
        // hit-testing loops forever on the main thread (see ReviewChatComposer).
        let view = TranscriptParagraphNSTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.allowsUndo = false
        view.usesFontPanel = false
        view.isAutomaticLinkDetectionEnabled = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        configure(view)
        return view
    }

    func updateNSView(_ view: TranscriptParagraphNSTextView, context: Context) {
        configure(view)
    }

    /// Narrower than any glyph. A proposal under this is a stack's
    /// minimum-width probe, not a width anything will be drawn at.
    private static let narrowestMeasuredWidth: CGFloat = 8

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: TranscriptParagraphNSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else {
            return view.unconstrainedSize()
        }
        // A paragraph wraps down to nothing, and laying a thousand characters
        // out one to a line to say so is what a zero-width probe costs.
        guard width >= Self.narrowestMeasuredWidth else {
            return CGSize(width: max(width, 0), height: view.unconstrainedSize().height)
        }
        return CGSize(width: width, height: view.height(forWidth: width))
    }

    static func dismantleNSView(_ view: TranscriptParagraphNSTextView, coordinator: Delegate) {
        view.coordinator?.unregister(view)
        view.coordinator = nil
    }

    private func configure(_ view: TranscriptParagraphNSTextView) {
        if view.coordinator !== selection {
            view.coordinator?.unregister(view)
            view.coordinator = selection
        }
        if view.key != key {
            // Re-used for another paragraph: whatever it had selected belonged
            // to the old one.
            if view.selectedRange().length > 0 {
                view.setSelectedRange(NSRange(location: 0, length: 0))
            }
            view.key = key
        }
        selection.register(view, for: key)
        view.sliceRange = sliceRange
        view.findState = findState
        view.seekAction = seekAction
        if view.appearance?.name != appearance?.name {
            view.appearance = appearance
        }
        view.apply(text: text, font: font, lineSpacing: lineSpacing, textColor: .labelColor)
        view.paintHighlights(localHighlights)
        view.paintFindMatches(localFindMatches)
    }

    private var localHighlights: [(id: String, color: SourceHighlightColor, range: NSRange)] {
        let slice = sliceRange
        return highlights.compactMap { placement in
            guard let range = placement.localRange(inField: key.field, sliceRange: slice) else { return nil }
            return (placement.highlightID, placement.color, range)
        }
    }

    private var localFindMatches: [(range: NSRange, color: NSColor)] {
        let length = sliceRange.length
        return findMatches.compactMap { match in
            guard match.field == key.field else { return nil }
            let localLocation = match.location - key.sourceUTF16Offset
            guard localLocation >= 0, localLocation + match.length <= length else { return nil }
            let color = match == selectedFindMatch
                ? NSColor.systemOrange.withAlphaComponent(0.62)
                : NSColor.systemYellow.withAlphaComponent(0.32)
            return (NSRange(location: localLocation, length: match.length), color)
        }
    }

    final class Delegate: NSObject, NSTextViewDelegate {
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? TranscriptParagraphNSTextView else { return }
            // Deferred: AppKit posts this mid-gesture, and the coordinator may
            // move another view's selection in response.
            DispatchQueue.main.async {
                if view.programmaticSelection.isActive {
                    view.coordinator?.callout.hide()
                    return
                }
                view.coordinator?.selectionDidChange(in: view)
            }
        }
    }
}
