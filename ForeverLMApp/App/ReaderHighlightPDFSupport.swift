import AppKit
import CryptoKit
import Foundation
import PDFKit

/// Turning a `PDFView` selection into a note anchor, and painting saved notes
/// back onto the page.
///
/// Highlights are drawn as PDFKit highlight annotations, so they track scroll,
/// zoom and page layout without any overlay bookkeeping, and PDFKit reports
/// clicks on them for free. The annotations only ever exist in the reader's
/// in-memory `PDFDocument` — nothing here writes the file back to disk.
///
/// Every entry point takes an optional `pageRange`. A book is read as one
/// document assembled from its chapter PDFs, but its notes are stored per
/// chapter and numbered in the chapter's own pages; the range is the chapter's
/// pages within the book, and anchors are made and resolved relative to it.
/// Without a range the whole document is the source, as it is for a paper.
enum ReaderPDFHighlightSupport {
    /// Marks our annotations so they can be found again for repainting and
    /// hit-testing, and so a document's own highlights are left alone.
    static let annotationPrefix = "foreverlm-note:"

    // MARK: Anchoring

    /// Both anchors for a live PDF selection: the page geometry PDFKit paints
    /// from, and the portable text-quote anchor that survives the PDF being
    /// re-fetched or the source being read somewhere else.
    static func anchors(
        for selection: PDFSelection,
        in document: PDFDocument,
        pageRange: Range<Int>? = nil
    ) -> (text: ReaderTextAnchor, pdf: ReaderPDFAnchor)? {
        let quote = selection.string ?? ""
        guard !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let page = selection.pages.first else { return nil }

        let pageIndex = document.index(for: page)
        let range = pageRange ?? 0..<document.pageCount
        guard pageIndex != NSNotFound, range.contains(pageIndex) else { return nil }

        // One rect per line rather than one union, so a passage wrapping across
        // lines is painted as text rather than as a block covering the margin.
        var rects: [CGRect] = []
        for line in selection.selectionsByLine() {
            for linePage in line.pages where linePage === page {
                let bounds = line.bounds(for: linePage)
                if !bounds.isNull, !bounds.isEmpty { rects.append(bounds) }
            }
        }
        if rects.isEmpty {
            let bounds = selection.bounds(for: page)
            guard !bounds.isNull, !bounds.isEmpty else { return nil }
            rects = [bounds]
        }

        return (
            textAnchor(
                for: selection,
                page: page,
                pagesBefore: range.lowerBound..<pageIndex,
                in: document,
                quote: quote
            ),
            ReaderPDFAnchor(pageIndex: pageIndex - range.lowerBound, rects: rects)
        )
    }

    /// The portable anchor, measured against the source's text so its offset
    /// means the same thing as one produced by a web or transcript reader.
    private static func textAnchor(
        for selection: PDFSelection,
        page: PDFPage,
        pagesBefore: Range<Int>,
        in document: PDFDocument,
        quote: String
    ) -> ReaderTextAnchor {
        let pageText = page.string ?? ""
        guard !pageText.isEmpty else { return ReaderTextAnchor(exact: quote) }

        // PDFKit can name the exact character the selection starts on, which
        // beats searching the page text for a quote that may appear on it more
        // than once.
        let startIndex = characterIndex(of: selection, on: page).flatMap {
            pageText.index(pageText.startIndex, offsetBy: $0, limitedBy: pageText.endIndex)
        } ?? pageText.range(of: quote)?.lowerBound

        guard let startIndex else { return ReaderTextAnchor(exact: quote) }
        let endIndex = pageText.index(
            startIndex,
            offsetBy: quote.count,
            limitedBy: pageText.endIndex
        ) ?? pageText.endIndex

        var anchor = ReaderTextAnchor(text: pageText, range: startIndex..<endIndex)
        // `anchor.offset` is page-relative so far; shift it into source space.
        anchor.exact = quote
        anchor.offset += normalizedLength(ofPages: pagesBefore, in: document)
        return anchor
    }

    /// Where the selection starts within its page's text, via the point PDFKit
    /// reports for the first line of the selection.
    private static func characterIndex(of selection: PDFSelection, on page: PDFPage) -> Int? {
        let firstLine = selection.selectionsByLine().first ?? selection
        let bounds = firstLine.bounds(for: page)
        guard !bounds.isNull, !bounds.isEmpty else { return nil }
        // A point just inside the leading edge, vertically centered on the line.
        let probe = CGPoint(x: bounds.minX + 1, y: bounds.midY)
        let index = page.characterIndex(at: probe)
        return index >= 0 ? index : nil
    }

    /// Whitespace-collapsed length of the given pages, which is how far into
    /// the source the text of the page after them begins.
    private static func normalizedLength(ofPages pages: Range<Int>, in document: PDFDocument) -> Int {
        var total = 0
        for index in pages where index >= 0 && index < document.pageCount {
            guard let text = document.page(at: index)?.string, !text.isEmpty else { continue }
            // Plus one for the space the page break collapses to.
            total += ReaderTextAnchor.normalize(text).text.count + 1
        }
        return total
    }

    // MARK: Painting

    /// Installs annotations for `highlights`, which belong to the source whose
    /// pages are `pageRange`. The caller retains the returned annotations and
    /// removes them before repainting, so repainting never scans every page of
    /// a potentially large PDF on the main actor.
    static func paint(
        _ highlights: [SourceHighlight],
        into document: PDFDocument,
        pageRange: Range<Int>? = nil
    ) -> [PDFAnnotation] {
        var installed: [PDFAnnotation] = []
        for highlight in highlights {
            // A clip is outlined where it was cut, dashed in the Canvas's clip
            // colour; a click opens its card like any mark's.
            if let clip = ReaderClip.reference(of: highlight), let crop = clip.crop, case .page(let number) = clip.location {
                let range = pageRange ?? 0..<document.pageCount
                let pageIndex = number - 1 + range.lowerBound
                guard range.contains(pageIndex), let page = document.page(at: pageIndex), page.rotation % 360 == 0 else { continue }
                let annotation = PDFAnnotation(bounds: ReaderClipTool.pageRect(crop, on: page), forType: .square, withProperties: nil)
                let border = PDFBorder()
                border.lineWidth = 1.5
                border.style = .dashed
                border.dashPattern = [5, 3]
                annotation.border = border
                annotation.color = NSColor(red: 0.83, green: 0.33, blue: 0.49, alpha: 0.85)
                annotation.userName = annotationPrefix + highlight.id
                page.addAnnotation(annotation)
                installed.append(annotation)
                continue
            }
            guard let anchor = resolvedPDFAnchor(for: highlight, in: document, pageRange: pageRange),
                  let page = document.page(at: anchor.pageIndex) else { continue }
            for rect in anchor.rects where !rect.isNull && !rect.isEmpty {
                let annotation = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
                annotation.color = color(for: highlight.color)
                annotation.userName = annotationPrefix + highlight.id
                // No `contents`: PDFView draws a speech-bubble glyph at the
                // right end of every annotation that carries text, one per
                // line rect, and a line that stops short of the margin puts
                // its glyph over the words. The mark is the whole affordance;
                // clicking it opens the note.
                page.addAnnotation(annotation)
                installed.append(annotation)
            }
        }
        return installed
    }

    static func remove(_ annotations: [PDFAnnotation]) {
        for annotation in annotations {
            annotation.page?.removeAnnotation(annotation)
        }
    }

    static func isNoteAnnotation(_ annotation: PDFAnnotation) -> Bool {
        annotation.userName?.hasPrefix(annotationPrefix) == true
    }

    /// The highlight ID a clicked annotation belongs to, if it is one of ours.
    static func highlightID(for annotation: PDFAnnotation) -> String? {
        guard let userName = annotation.userName, userName.hasPrefix(annotationPrefix) else { return nil }
        return String(userName.dropFirst(annotationPrefix.count))
    }

    /// Where a highlight should be painted, in the document's own page numbers:
    /// its stored quads when the page still matches, otherwise the passage
    /// found by its text anchor.
    ///
    /// The re-anchoring path is what makes a note survive a PDF being
    /// re-downloaded with different pagination — the quads would then point at
    /// the wrong words, so they are only trusted when the page still reads the
    /// way it did when the note was made.
    private static func resolvedPDFAnchor(
        for highlight: SourceHighlight,
        in document: PDFDocument,
        pageRange: Range<Int>?
    ) -> ReaderPDFAnchor? {
        let range = pageRange ?? 0..<document.pageCount
        if let stored = highlight.pdfAnchor {
            let pageIndex = stored.pageIndex + range.lowerBound
            if range.contains(pageIndex),
               let page = document.page(at: pageIndex),
               pageStillContainsQuote(highlight.quote, on: page) {
                return ReaderPDFAnchor(pageIndex: pageIndex, rects: stored.rects)
            }
        }
        return searchAnchor(for: highlight, in: document, pageRange: range)
    }

    private static func pageStillContainsQuote(_ quote: String, on page: PDFPage) -> Bool {
        guard let pageText = page.string else { return false }
        let haystack = ReaderTextAnchor.normalize(pageText).text
        let needle = ReaderTextAnchor.normalize(quote).text
        guard !needle.isEmpty else { return false }
        return haystack.contains(needle)
    }

    /// Finds the passage again by searching page text, then converts the found
    /// range back into page geometry with PDFKit's own selection search.
    private static func searchAnchor(
        for highlight: SourceHighlight,
        in document: PDFDocument,
        pageRange: Range<Int>
    ) -> ReaderPDFAnchor? {
        let needle = ReaderTextAnchor.normalize(highlight.quote).text
        guard !needle.isEmpty else { return nil }

        // PDFKit's own search returns selections with page geometry attached,
        // which is exactly what painting needs; the text anchor then picks the
        // right one when a source repeats the passage. Only the source's own
        // pages are candidates — a book repeats phrases across chapters.
        var matches = document.findString(highlight.quote, withOptions: [.caseInsensitive])
            .filter { match in
                guard let page = match.pages.first else { return false }
                return pageRange.contains(document.index(for: page))
            }
        if matches.isEmpty {
            matches = projectedMatches(for: highlight.quote, in: document, pageRange: pageRange)
        }
        guard !matches.isEmpty else { return nil }

        let best = matches.min { lhs, rhs in
            score(for: lhs, highlight: highlight, in: document, pageRange: pageRange)
                < score(for: rhs, highlight: highlight, in: document, pageRange: pageRange)
        }
        guard let best, let page = best.pages.first else { return nil }
        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound else { return nil }

        var rects: [CGRect] = []
        for line in best.selectionsByLine() {
            for linePage in line.pages where linePage === page {
                let bounds = line.bounds(for: linePage)
                if !bounds.isNull, !bounds.isEmpty { rects.append(bounds) }
            }
        }
        guard !rects.isEmpty else { return nil }
        return ReaderPDFAnchor(pageIndex: pageIndex, rects: rects)
    }

    /// The passage on each page of `pageRange` whose text holds it in the
    /// projection every reader resolves an anchor in (`ReaderTextAnchor`).
    /// PDFKit's search compares characters as printed, so a quote taken from
    /// the stored text — an assistant's mark made over MCP — is not found on a
    /// page that keeps a soft hyphen inside one of its words, where the stored
    /// text keeps none (`removingSoftHyphens()`). Read only when PDFKit's own
    /// search finds nothing.
    private static func projectedMatches(
        for quote: String,
        in document: PDFDocument,
        pageRange: Range<Int>
    ) -> [PDFSelection] {
        var matches: [PDFSelection] = []
        for index in pageRange where index >= 0 && index < document.pageCount {
            guard let page = document.page(at: index),
                  let text = page.string, !text.isEmpty,
                  let range = ReaderTextAnchor(exact: quote).resolve(in: text),
                  let selection = page.selection(for: NSRange(range, in: text)) else { continue }
            matches.append(selection)
        }
        return matches
    }

    /// Lower is better: how far a candidate sits from where the note was made.
    private static func score(
        for selection: PDFSelection,
        highlight: SourceHighlight,
        in document: PDFDocument,
        pageRange: Range<Int>
    ) -> Int {
        guard let page = selection.pages.first else { return .max }
        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound else { return .max }
        let candidateOffset = normalizedLength(ofPages: pageRange.lowerBound..<pageIndex, in: document)
            + (characterIndex(of: selection, on: page) ?? 0)
        return abs(candidateOffset - highlight.anchor.offset)
    }

    static func color(for highlightColor: SourceHighlightColor) -> NSColor {
        let rgb = highlightColor.components
        return NSColor(
            srgbRed: rgb.red,
            green: rgb.green,
            blue: rgb.blue,
            alpha: 1.0
        )
    }

    /// Scrolls a PDF reader to a saved note and flashes its passage selected.
    static func reveal(_ highlight: SourceHighlight, in pdfView: PDFView, pageRange: Range<Int>? = nil) {
        guard let document = pdfView.document,
              let anchor = resolvedPDFAnchor(for: highlight, in: document, pageRange: pageRange),
              let page = document.page(at: anchor.pageIndex) else { return }
        let target = anchor.rects.reduce(CGRect.null) { $0.union($1) }
        guard !target.isNull else { return }
        pdfView.go(to: target, on: page)
    }
}

// MARK: - Importing another app's marks

/// Highlights and notes made in another app, brought in as ForeverLM
/// highlights on the paper whose PDF they were made on: those saved inside the
/// file (Preview, Acrobat, a PDF exported from Paperpile or Mendeley with its
/// annotations) and those Zotero keeps in its own library.
///
/// Each becomes an ordinary `SourceHighlight` with both anchors a mark made in
/// the reader has, so it paints, lists, searches and syncs like one. Its id is
/// derived from the source and the mark's `originKey`, which is what makes a
/// second import of the same PDF or library add nothing.
extension ReaderPDFHighlightSupport {
    /// PDF annotation subtypes that mark words.
    private static let passageSubtypes: Set<String> = ["highlight", "underline", "strikeout", "squiggly"]
    /// Subtypes that are a comment placed on the page: a sticky note, a text box.
    private static let pinnedNoteSubtypes: Set<String> = ["text", "freetext"]

    /// `Highlight`, `/Highlight` and `highlight` alike.
    private static func subtype(of annotation: PDFAnnotation) -> String {
        (annotation.type ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }

    /// The highlights and notes saved inside a PDF, in page order. Links,
    /// form fields, shapes, ink and popups are not marks on the text and are
    /// left out, as are ForeverLM's own painted marks.
    static func embeddedMarks(in document: PDFDocument) -> [ImportedPDFMark] {
        guard !document.isLocked else { return [] }
        var marks: [ImportedPDFMark] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations where !isNoteAnnotation(annotation) {
                let subtype = subtype(of: annotation)
                let kind: ImportedPDFMark.Kind
                if passageSubtypes.contains(subtype) {
                    kind = .passage
                } else if pinnedNoteSubtypes.contains(subtype) {
                    kind = .pinnedNote
                } else {
                    continue
                }
                let rects = kind == .passage ? markupRects(of: annotation) : [annotation.bounds]
                guard !rects.isEmpty else { continue }
                // The comment is the annotation's own text; some writers keep
                // it only on the popup that opens from it.
                var comment = (annotation.contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if comment.isEmpty {
                    comment = (annotation.popup?.contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if kind == .pinnedNote, comment.isEmpty { continue }
                marks.append(ImportedPDFMark(
                    kind: kind,
                    pageIndex: pageIndex,
                    rects: rects,
                    text: nil,
                    comment: comment,
                    color: markerColor(annotation.color),
                    createdAt: annotation.modificationDate,
                    originKey: "pdf:\(pageIndex):\(subtype):\(geometryKey(rects))"
                ))
            }
        }
        return marks
    }

    /// The highlights `marks` become on `sourceID`, measured against
    /// `document`. A mark whose page is gone, or whose rectangles hold no
    /// words the page or the other app can name (a mark over a figure), is
    /// left out: a highlight is a passage.
    static func importedHighlights(
        _ marks: [ImportedPDFMark],
        sourceID: String,
        in document: PDFDocument,
        importedAt now: Date = Date()
    ) -> [SourceHighlight] {
        guard !marks.isEmpty, !document.isLocked else { return [] }
        // Reading order — page, then top to bottom (PDF y grows upward) — so a
        // mark with no date of its own still lists where it sits.
        let ordered = marks.enumerated().sorted { lhs, rhs in
            if lhs.element.pageIndex != rhs.element.pageIndex {
                return lhs.element.pageIndex < rhs.element.pageIndex
            }
            let lhsTop = lhs.element.rects.map(\.maxY).max() ?? 0
            let rhsTop = rhs.element.rects.map(\.maxY).max() ?? 0
            if lhsTop != rhsTop { return lhsTop > rhsTop }
            return lhs.offset < rhs.offset
        }.map(\.element)

        var pageStarts: [Int] = []
        var highlights: [SourceHighlight] = []
        var seenIDs = Set<String>()
        for (position, mark) in ordered.enumerated() {
            // A library's copy of a paper can be a different printing with
            // fewer pages than the one its marks were made on.
            guard (0..<document.pageCount).contains(mark.pageIndex),
                  let page = document.page(at: mark.pageIndex) else { continue }
            let placed: (quote: String, rects: [CGRect])?
            switch mark.kind {
            case .passage: placed = passage(of: mark, on: page)
            case .pinnedNote: placed = nearestLine(to: mark, on: page)
            }
            guard let placed else { continue }
            let id = importedHighlightID(sourceID: sourceID, originKey: mark.originKey)
            guard seenIDs.insert(id).inserted else { continue }

            // Page offsets are measured once per import, up to the last page
            // a mark needs, rather than once per mark.
            while pageStarts.count <= mark.pageIndex {
                let previous = pageStarts.count
                let start = previous == 0 ? 0 : pageStarts[previous - 1]
                    + normalizedLength(ofPages: (previous - 1)..<previous, in: document)
                pageStarts.append(start)
            }

            // Acrobat stores the marked words as the comment of a bare
            // highlight; that is not something the reader wrote.
            let comment = ReaderTextAnchor.normalize(mark.comment.lowercased()).text
                == ReaderTextAnchor.normalize(placed.quote.lowercased()).text ? "" : mark.comment
            highlights.append(SourceHighlight(
                id: id,
                sourceID: sourceID,
                quote: placed.quote,
                note: comment,
                color: mark.color,
                anchor: importedTextAnchor(
                    quote: placed.quote,
                    at: placed.rects[0],
                    on: page,
                    pageStart: pageStarts[mark.pageIndex]
                ),
                pdfAnchor: ReaderPDFAnchor(pageIndex: mark.pageIndex, rects: placed.rects),
                createdAt: mark.createdAt ?? now.addingTimeInterval(Double(position) * 0.001),
                updatedAt: now
            ))
        }
        return highlights
    }

    /// `hl_` and a UUID-shaped digest of the source and the mark's origin:
    /// the same shape as `SourceHighlight.newID()`, and the same value every
    /// time the same mark is imported onto the same source.
    static func importedHighlightID(sourceID: String, originKey: String) -> String {
        let digest = SHA256.hash(data: Data("\(sourceID)\n\(originKey)".utf8))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        let groups = [
            hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4),
            hex.dropFirst(16).prefix(4), hex.dropFirst(20),
        ]
        return "hl_" + groups.joined(separator: "-")
    }

    /// The marked words and where they sit. The words PDFKit reads under the
    /// rectangles are preferred when the page's text contains them, because
    /// painting trusts a stored mark's geometry only while its page still
    /// reads its quote; the other app's own reading of them is the fallback.
    private static func passage(of mark: ImportedPDFMark, on page: PDFPage) -> (quote: String, rects: [CGRect])? {
        let pageText = ReaderTextAnchor.normalize(page.string ?? "").text
        let underRects = mark.rects.compactMap { rect in
            // The middle of each line box: a box drawn a little tall reaches
            // into the lines above and below.
            page.selection(for: rect.insetBy(dx: 0, dy: rect.height * 0.25))?.string
        }.joined(separator: " ")
        let candidates = [underRects, mark.text ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let fallback = candidates.last else { return nil }
        let quote = candidates.first { candidate in
            let needle = ReaderTextAnchor.normalize(candidate).text
            return !needle.isEmpty && pageText.contains(needle)
        } ?? fallback
        return (quote, mark.rects)
    }

    /// The line of text nearest a note pinned to the page: what the note is
    /// about, as near as the page can say, and what a highlight needs to be
    /// found again. The search widens from the note's own height to the whole
    /// page, since a sticky note usually sits in the margin.
    private static func nearestLine(to mark: ImportedPDFMark, on page: PDFPage) -> (quote: String, rects: [CGRect])? {
        guard let spot = mark.rects.first else { return nil }
        let pageBounds = page.bounds(for: .cropBox)
        let center = CGPoint(x: spot.midX, y: spot.midY)
        for reach in [max(spot.height / 2, 6), 36, 120, pageBounds.height] as [CGFloat] {
            let band = CGRect(
                x: pageBounds.minX,
                y: center.y - reach,
                width: pageBounds.width,
                height: reach * 2
            ).intersection(pageBounds)
            guard !band.isNull, !band.isEmpty, let selection = page.selection(for: band) else { continue }
            let lines = selection.selectionsByLine().compactMap { line -> (text: String, bounds: CGRect)? in
                let text = (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let bounds = line.bounds(for: page)
                guard !text.isEmpty, !bounds.isNull, !bounds.isEmpty else { return nil }
                return (text, bounds)
            }
            if let nearest = lines.min(by: {
                lineDistance(from: center, to: $0.bounds) < lineDistance(from: center, to: $1.bounds)
            }) {
                return (nearest.text, [nearest.bounds])
            }
        }
        return nil
    }

    /// Vertical distance counts four times horizontal, so the line level with
    /// a margin note beats a nearer line above or below it.
    private static func lineDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dy * 4 + dx
    }

    /// The portable anchor for an imported quote, in the same source-space
    /// offsets `anchors(for:in:)` produces. Where the mark starts on the page
    /// picks between repeats of the same words.
    private static func importedTextAnchor(
        quote: String,
        at firstRect: CGRect,
        on page: PDFPage,
        pageStart: Int
    ) -> ReaderTextAnchor {
        guard let pageText = page.string, !pageText.isEmpty else { return ReaderTextAnchor(exact: quote) }
        var hint = 0
        let characterIndex = page.characterIndex(at: CGPoint(x: firstRect.minX + 1, y: firstRect.midY))
        if characterIndex > 0 {
            hint = ReaderTextAnchor.normalize(String(pageText.prefix(characterIndex))).text.count
        }
        guard let range = ReaderTextAnchor(exact: quote, offset: hint).resolve(in: pageText) else {
            return ReaderTextAnchor(exact: quote, offset: pageStart + hint)
        }
        var anchor = ReaderTextAnchor(text: pageText, range: range)
        anchor.exact = quote
        anchor.offset += pageStart
        return anchor
    }

    /// One rectangle per quadrilateral of a highlight, underline or strikeout.
    ///
    /// PDFKit reports quadrilateral points relative to the annotation's
    /// bounds; a point list already in page space is recognised by landing
    /// inside the bounds as given. With neither, the bounds stand in.
    private static func markupRects(of annotation: PDFAnnotation) -> [CGRect] {
        let bounds = annotation.bounds
        let points = (annotation.quadrilateralPoints ?? []).map(\.pointValue)
        let fallback = bounds.isNull || bounds.isEmpty ? [] : [bounds]
        guard points.count >= 4 else { return fallback }
        func boxes(offset: CGPoint) -> [CGRect] {
            stride(from: 0, to: points.count - points.count % 4, by: 4).compactMap { start in
                let quad = points[start..<(start + 4)]
                let xs = quad.map(\.x)
                let ys = quad.map(\.y)
                guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
                let rect = CGRect(x: minX + offset.x, y: minY + offset.y, width: maxX - minX, height: maxY - minY)
                return rect.isEmpty ? nil : rect
            }
        }
        let slack = bounds.insetBy(dx: -2, dy: -2)
        for candidate in [boxes(offset: bounds.origin), boxes(offset: .zero)]
        where !candidate.isEmpty && candidate.allSatisfy({ slack.contains($0) }) {
            return candidate
        }
        return fallback
    }

    private static func markerColor(_ color: NSColor?) -> SourceHighlightColor {
        guard let rgb = color?.usingColorSpace(.sRGB) else { return .default }
        return SourceHighlightColor(
            nearestTo: Double(rgb.redComponent),
            green: Double(rgb.greenComponent),
            blue: Double(rgb.blueComponent)
        )
    }

    /// Whole-point geometry: stable across two reads of the same file.
    private static func geometryKey(_ rects: [CGRect]) -> String {
        rects.map { rect in
            [rect.minX, rect.minY, rect.maxX, rect.maxY]
                .map { String(Int($0.rounded())) }
                .joined(separator: ",")
        }.joined(separator: ";")
    }

    // MARK: Hiding the document's own copies

    /// The document's own marks that painted ForeverLM highlights stand in
    /// for, taken off their pages: an imported highlight would otherwise be
    /// tinted twice, once by the file and once by the reader, and the file's
    /// copy would take the click that should open the note. A pinned note is
    /// hidden when a highlight on its page carries its words as the note.
    ///
    /// Only the in-memory document changes. The hidden marks are returned so
    /// `restoreDocumentMarks` can put them back before the next repaint: a
    /// highlight deleted here leaves the file's own mark showing, as the file
    /// still has it.
    static func hideDocumentMarks(
        coveredBy painted: [PDFAnnotation],
        notes: Set<String>
    ) -> [(annotation: PDFAnnotation, page: PDFPage)] {
        var paintedByPage: [ObjectIdentifier: (page: PDFPage, rects: [CGRect])] = [:]
        for annotation in painted {
            guard let page = annotation.page else { continue }
            paintedByPage[ObjectIdentifier(page), default: (page, [])].rects.append(annotation.bounds)
        }
        var hidden: [(annotation: PDFAnnotation, page: PDFPage)] = []
        for (page, paintedRects) in paintedByPage.values {
            for annotation in page.annotations where !isNoteAnnotation(annotation) {
                let subtype = subtype(of: annotation)
                let covered: Bool
                if passageSubtypes.contains(subtype) {
                    covered = markupRects(of: annotation).contains { rect in
                        paintedRects.contains { overlapRatio(rect, $0) > 0.5 }
                    }
                } else if pinnedNoteSubtypes.contains(subtype) {
                    let words = ReaderTextAnchor.normalize(annotation.contents ?? "").text
                    covered = !words.isEmpty && notes.contains(words)
                } else {
                    covered = false
                }
                guard covered else { continue }
                page.removeAnnotation(annotation)
                hidden.append((annotation, page))
            }
        }
        return hidden
    }

    static func restoreDocumentMarks(_ hidden: [(annotation: PDFAnnotation, page: PDFPage)]) {
        for (annotation, page) in hidden {
            page.addAnnotation(annotation)
        }
    }

    /// How much of the smaller rectangle the two share.
    private static func overlapRatio(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let shared = lhs.intersection(rhs)
        guard !shared.isNull, !shared.isEmpty else { return 0 }
        let smaller = min(lhs.width * lhs.height, rhs.width * rhs.height)
        guard smaller > 0 else { return 0 }
        return (shared.width * shared.height) / smaller
    }
}
