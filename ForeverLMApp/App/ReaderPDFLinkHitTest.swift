import AppKit
import PDFKit

/// The link under a point on a PDF page, whatever is painted over it.
///
/// `PDFPage.annotation(at:)` answers the topmost annotation at a point, and a
/// highlight is painted after the page's own links, so it lies over a citation
/// it covers and takes the click, the hover and the start of a drag meant for
/// the citation (product owner, 2026-11-04: "when there is a highlight, i should
/// still be able to click the reference (should take precedence over the
/// highlight when i click e.g. that 7 superscript)"). A mark over words does
/// not hide what the words link to, so the reader asks here instead; a click
/// elsewhere on the highlight still reaches the highlight.
enum ReaderPDFLinkHitTest {
    /// A link at `point` (page coordinates) and whether a mark lies over it.
    /// Nil when the topmost annotation there is not a link and no mark covers
    /// one, as when the walkthrough's outline is what is under the pointer.
    static func link(at point: CGPoint, on page: PDFPage) -> (annotation: PDFAnnotation, coveredByMark: Bool)? {
        guard let top = page.annotation(at: point) else { return nil }
        if isLink(top) { return (top, false) }
        guard isMarkOverText(top) else { return nil }
        // Later annotations are painted over earlier ones.
        guard let link = page.annotations.last(where: { isLink($0) && $0.bounds.contains(point) }) else { return nil }
        return (link, true)
    }

    /// The address a link opens, for a link PDFKit will not follow itself
    /// because a mark lies over it.
    static func externalURL(of link: PDFAnnotation) -> URL? {
        link.url ?? (link.action as? PDFActionURL)?.url
    }

    private static func isLink(_ annotation: PDFAnnotation) -> Bool {
        subtype(of: annotation) == "link"
    }

    /// A highlight the reader painted, or one the document brought: marks
    /// that sit on words and say nothing of their own where they are pressed.
    private static func isMarkOverText(_ annotation: PDFAnnotation) -> Bool {
        ReaderPDFHighlightSupport.isNoteAnnotation(annotation)
            || ["highlight", "underline", "strikeout", "squiggly"].contains(subtype(of: annotation))
    }

    /// `Link`, `/Link` and `link` alike.
    private static func subtype(of annotation: PDFAnnotation) -> String {
        (annotation.type ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }
}
