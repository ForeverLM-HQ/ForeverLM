import AppKit
import Foundation

/// Anchoring and painting for the readers that render into an `NSTextView` —
/// plain-text EPUB chapters and the text chapters the pop-out reader shows.
///
/// Background colour goes onto the view's own text storage rather than layout
/// manager temporary attributes: these readers replace their string wholesale
/// on every chapter change, and repainting after that replacement is one call
/// instead of a relayout race.
enum ReaderTextViewHighlightSupport {
    private static let markerAttribute = NSAttributedString.Key("ForeverLMReaderHighlight")

    /// The anchor for whatever the text view has selected, or nil when the
    /// selection is empty.
    static func anchor(for textView: NSTextView) -> (quote: String, anchor: ReaderTextAnchor)? {
        anchor(in: textView.string, selectedRange: textView.selectedRange())
    }

    /// Split out from the view so the anchoring rules are testable without AppKit.
    static func anchor(in text: String, selectedRange: NSRange) -> (quote: String, anchor: ReaderTextAnchor)? {
        guard selectedRange.length > 0,
              let range = Range(selectedRange, in: text) else { return nil }
        let quote = String(text[range])
        guard !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (quote, ReaderTextAnchor(text: text, range: range))
    }

    /// Repaints every highlight onto the text view, dropping any that no longer
    /// resolve — a chapter that was re-fetched with the passage removed simply
    /// shows no mark rather than a mark on the wrong words.
    static func paint(_ highlights: [SourceHighlight], into textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        var previouslyPaintedRanges: [NSRange] = []
        storage.enumerateAttribute(markerAttribute, in: fullRange) { value, range, _ in
            if value != nil { previouslyPaintedRanges.append(range) }
        }
        storage.beginEditing()
        for range in previouslyPaintedRanges {
            storage.removeAttribute(.backgroundColor, range: range)
            storage.removeAttribute(markerAttribute, range: range)
        }
        for highlight in highlights {
            guard let range = resolvedRange(for: highlight, in: textView.string) else { continue }
            storage.addAttribute(markerAttribute, value: highlight.id, range: range)
            storage.addAttribute(
                .backgroundColor,
                value: color(for: highlight.color),
                range: range
            )
        }
        storage.endEditing()
    }

    /// The highlight covering a click, so pressing a marked passage opens its
    /// note.
    static func highlight(
        at point: CGPoint,
        in textView: NSTextView,
        among highlights: [SourceHighlight]
    ) -> SourceHighlight? {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return nil }
        let origin = textView.textContainerOrigin
        let containerPoint = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: container)
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)

        let text = textView.string
        return highlights.first { highlight in
            guard let range = resolvedRange(for: highlight, in: text) else { return false }
            return NSLocationInRange(characterIndex, range)
        }
    }

    /// Scrolls the passage into view and selects it, so a note opened from the
    /// list lands on the words it was written about.
    static func reveal(_ highlight: SourceHighlight, in textView: NSTextView) {
        guard let range = resolvedRange(for: highlight, in: textView.string) else { return }
        textView.scrollRangeToVisible(range)
        textView.setSelectedRange(range)
        textView.showFindIndicator(for: range)
    }

    static func resolvedRange(for highlight: SourceHighlight, in text: String) -> NSRange? {
        guard let range = highlight.anchor.resolve(in: text) else { return nil }
        return NSRange(range, in: text)
    }

    /// The painted passage's frame on screen, so its card can hang below it.
    static func frameOnScreen(of highlight: SourceHighlight, in textView: NSTextView) -> CGRect? {
        guard let range = resolvedRange(for: highlight, in: textView.string),
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return nil }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        guard !rect.isEmpty else { return nil }
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        return textView.screenFrame(of: rect)
    }

    static func color(for highlightColor: SourceHighlightColor) -> NSColor {
        let rgb = highlightColor.components
        // Lighter than the PDF fill: this sits directly behind body text rather
        // than as a translucent layer over a rendered page.
        return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 0.45)
    }
}
