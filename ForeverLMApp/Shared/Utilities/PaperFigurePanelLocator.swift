#if canImport(PDFKit)
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import CoreGraphics
import Foundation
import PDFKit

/// Finds a figure's panels from the page's own text layer, without a vision call.
///
/// A multi-panel figure prints its panel letters — A, B, C or a, b, c — as
/// text inside the figure, and a PDF made from vector figures keeps them in
/// its text layer: a bold single-letter run, set a size or two above the axis
/// labels and legends around it. On the page index 20 of the lysosome-aging
/// preprint (2026-09-19), the letters are Arial-BoldMT at 8.8 pt while every
/// tick label and legend is bold at 4.2 pt or regular at 6.2 pt. That gap is
/// what this reads: the lines whose first token is one letter in a bold face
/// at a size near the largest such letter are the panel labels.
///
/// The letters partition the figure. Each panel begins at its letter and runs
/// right to the next letter on its row and down to the first letter below it;
/// the first row reaches the figure's top edge and the first column its left
/// edge. The boxes are then trimmed to the ink inside them, never grown, so a
/// loose partition line cannot swallow a neighbour's plot.
///
/// This is the fallback under the vision pass: an analysed panel with a
/// rectangle wins, a figure without one gets these, and a figure whose text
/// layer carries no letters — a raster figure, a scan — keeps the whole-figure
/// crop. Coordinates are normalized with a top-left origin, the frame
/// `PaperFigureRect` uses everywhere.
enum PaperFigurePanelLocator {

    /// One line of the page's text inside the figure, as the locator reads it.
    struct TextLine: Equatable, Sendable {
        let text: String
        let fontName: String
        let pointSize: Double
        let isBold: Bool
        /// Normalized, top-left origin.
        let rect: PaperFigureRect
    }

    /// A panel letter and where it is printed.
    struct PanelAnchor: Equatable, Sendable {
        let label: String
        let rect: PaperFigureRect
        let pointSize: Double
    }

    /// Letters smaller than this share of the largest panel letter are tick
    /// labels and legend keys, not panels.
    static let minimumSizeShareOfLargestLetter = 0.75

    /// Breathing room a partition line stands off the next letter, as a share
    /// of the page's side.
    static let gutter = 0.004

    // MARK: - Reading the page

    /// The text lines inside `figure` on `page`, with the font of each line's
    /// first glyph. The selection API rather than `characterBounds(at:)`, for
    /// the reason `PaperFigureRectRefiner.captionBounds` gives: a selection
    /// carries its own geometry.
    static func textLines(in figure: PaperFigureRect, on page: PDFPage) -> [TextLine] {
        guard figure.isValid, page.rotation % 360 == 0 else { return [] }
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return [] }
        let region = CGRect(
            x: box.minX + figure.x * box.width,
            y: box.minY + (1 - figure.y - figure.height) * box.height,
            width: figure.width * box.width,
            height: figure.height * box.height
        )
        guard let selection = page.selection(for: region) else { return [] }
        var lines: [TextLine] = []
        for line in selection.selectionsByLine() {
            let text = (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let bounds = line.bounds(for: page)
            guard bounds.width > 0, bounds.height > 0 else { continue }
            var fontName = ""
            var pointSize = 0.0
            var bold = false
            if let font = PaperFigureRectRefiner.leadingFont(of: line) {
                fontName = font.fontName
                pointSize = Double(font.pointSize)
                bold = isBoldFont(font)
            }
            let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if bold, tokens.count >= 2, tokens.allSatisfy({ leadingPanelLetter(of: $0) != nil }) {
                // Two panel letters on one baseline — "B C" over two plots
                // side by side — come back as one line with one space between
                // them however far apart they are printed. Each letter is
                // placed by the word under a point along the line: the ends
                // are exact, and a letter between them is snapped from an
                // estimate.
                for (index, token) in tokens.enumerated() {
                    let share = tokens.count == 1 ? 0 : CGFloat(index) / CGFloat(tokens.count - 1)
                    let probeX = index == 0
                        ? bounds.minX + 1
                        : (index == tokens.count - 1 ? bounds.maxX - 1 : bounds.minX + bounds.width * share)
                    let probe = CGPoint(x: probeX, y: bounds.midY)
                    var wordBounds = CGRect(x: probeX - 1, y: bounds.minY, width: 2, height: bounds.height)
                    if let word = page.selectionForWord(at: probe),
                       (word.string ?? "").trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(token) == .orderedSame {
                        let found = word.bounds(for: page)
                        if found.width > 0, found.height > 0 { wordBounds = found }
                    }
                    lines.append(TextLine(
                        text: token,
                        fontName: fontName,
                        pointSize: pointSize,
                        isBold: bold,
                        rect: normalized(wordBounds, in: box)
                    ))
                }
                continue
            }
            lines.append(TextLine(
                text: text,
                fontName: fontName,
                pointSize: pointSize,
                isBold: bold,
                rect: normalized(bounds, in: box)
            ))
        }
        return lines
    }

    private static func normalized(_ bounds: CGRect, in box: CGRect) -> PaperFigureRect {
        PaperFigureRect(
            x: Double((bounds.minX - box.minX) / box.width),
            y: Double((box.maxY - bounds.maxY) / box.height),
            width: Double(bounds.width / box.width),
            height: Double(bounds.height / box.height)
        )
    }

    static func isBoldFont(_ font: PaperFigurePlatformFont) -> Bool {
        #if os(macOS)
        if font.fontDescriptor.symbolicTraits.contains(.bold) { return true }
        #else
        if font.fontDescriptor.symbolicTraits.contains(.traitBold) { return true }
        #endif
        let name = font.fontName.lowercased()
        return name.contains("bold") || name.contains("black") || name.contains("heavy") || name.contains("semibold")
    }

    // MARK: - Choosing the letters

    /// The panel letters among `lines`: a line whose first token is one letter
    /// in a bold face, at a size near the largest such letter, each letter
    /// once (the first in reading order), and only the letters that run in
    /// sequence — a stray bold "X" on an axis is not a panel.
    static func panelAnchors(from lines: [TextLine]) -> [PanelAnchor] {
        var candidates: [PanelAnchor] = []
        for line in lines where line.isBold && line.pointSize > 0 {
            guard let letter = leadingPanelLetter(of: line.text) else { continue }
            candidates.append(PanelAnchor(label: letter, rect: line.rect, pointSize: line.pointSize))
        }
        guard let largest = candidates.map(\.pointSize).max(), largest > 0 else { return [] }
        let sized = candidates.filter { $0.pointSize >= largest * minimumSizeShareOfLargestLetter }

        // Reading order: rows top to bottom, left to right within a row.
        let ordered = sized.sorted { lhs, rhs in
            if abs(lhs.rect.y - rhs.rect.y) > min(lhs.rect.height, rhs.rect.height) * 0.6 {
                return lhs.rect.y < rhs.rect.y
            }
            return lhs.rect.x < rhs.rect.x
        }
        var seen = Set<String>()
        var unique: [PanelAnchor] = []
        for anchor in ordered where seen.insert(anchor.label).inserted {
            unique.append(anchor)
        }
        return inSequence(unique)
    }

    /// The single letter a line opens with — "A", "a", "(A)", "A.", "A)" — or
    /// nil when the line opens with anything else. A letter glued to its title
    /// in one line ("E Lysosomes") still opens with the letter.
    static func leadingPanelLetter(of text: String) -> String? {
        guard let token = text.split(whereSeparator: { $0.isWhitespace }).first else { return nil }
        let bare = token.trimmingCharacters(in: CharacterSet(charactersIn: "()[].:"))
        guard bare.count == 1, let scalar = bare.unicodeScalars.first,
              CharacterSet.letters.contains(scalar), bare.uppercased() != bare.lowercased() else { return nil }
        return bare.uppercased()
    }

    /// The longest run of consecutive letters among `anchors` (A, B, C … or
    /// B, C, D when A was missed), keeping their reading order. One letter on
    /// its own is kept too: a figure with one labelled panel has one panel.
    static func inSequence(_ anchors: [PanelAnchor]) -> [PanelAnchor] {
        guard anchors.count > 1 else { return anchors }
        let byLetter = Dictionary(uniqueKeysWithValues: anchors.map { ($0.label, $0) })
        let codes = byLetter.keys.compactMap { $0.unicodeScalars.first?.value }.sorted()
        var bestRun: [UInt32] = []
        var run: [UInt32] = []
        for code in codes {
            if let last = run.last, code == last + 1 {
                run.append(code)
            } else {
                run = [code]
            }
            if run.count > bestRun.count { bestRun = run }
        }
        let kept = Set(bestRun.compactMap { Unicode.Scalar($0).map { String(Character($0)) } })
        return anchors.filter { kept.contains($0.label) }
    }

    // MARK: - Partition

    /// Each letter's panel: from the letter right to the next letter on its
    /// row and down to the first letter below, out to the figure's edge where
    /// there is no neighbour. Keys are upper-case letters.
    static func partition(_ anchors: [PanelAnchor], within figure: PaperFigureRect) -> [String: PaperFigureRect] {
        guard figure.isValid, !anchors.isEmpty else { return [:] }
        let figureRight = figure.x + figure.width
        let figureBottom = figure.y + figure.height
        func tolerance(_ anchor: PanelAnchor) -> Double { max(anchor.rect.height, 0.002) }

        // Top: this letter's own edge, or the figure's when no letter sits
        // above it. Any letter above means a row above, and a row's panels
        // reach across the figure between them, so the column does not matter.
        var tops: [String: Double] = [:]
        for anchor in anchors {
            let hasLetterAbove = anchors.contains { $0 != anchor && $0.rect.y < anchor.rect.y - tolerance(anchor) }
            tops[anchor.label] = hasLetterAbove ? max(figure.y, anchor.rect.y - gutter) : figure.y
        }

        // Right and bottom depend on each other: a panel runs right to the
        // nearest letter whose panel overlaps it vertically, and down to the
        // first letter below it within that width. A tall panel begun on the
        // row above (D beside B and C) and a short one beside a tall one (E
        // beside the lower half of C) both come out right when the two are
        // settled together, so they are iterated to a fixed point from
        // "every panel reaches the figure's bottom".
        var rights: [String: Double] = [:]
        var bottoms: [String: Double] = Dictionary(uniqueKeysWithValues: anchors.map { ($0.label, figureBottom) })
        func overlapsVertically(_ anchor: PanelAnchor, _ other: PanelAnchor) -> Bool {
            let bottom = bottoms[anchor.label] ?? figureBottom
            let otherBottom = bottoms[other.label] ?? figureBottom
            return other.rect.y < bottom - 1e-9 && otherBottom > anchor.rect.y + 1e-9
        }
        for _ in 0..<8 {
            var nextRights: [String: Double] = [:]
            for anchor in anchors {
                var right = figureRight
                for other in anchors where other != anchor && other.rect.x >= anchor.rect.x + anchor.rect.width
                    && overlapsVertically(anchor, other) {
                    right = min(right, other.rect.x - gutter)
                }
                nextRights[anchor.label] = right
            }
            var nextBottoms: [String: Double] = [:]
            for anchor in anchors {
                let a = anchor.rect
                let right = nextRights[anchor.label] ?? figureRight
                var bottom = figureBottom
                for other in anchors where other != anchor {
                    let o = other.rect
                    guard o.y > a.y + tolerance(anchor), o.x < right, o.x + o.width > a.x - gutter else { continue }
                    bottom = min(bottom, o.y - gutter)
                }
                nextBottoms[anchor.label] = bottom
            }
            let settled = nextRights == rights && nextBottoms == bottoms
            rights = nextRights
            bottoms = nextBottoms
            if settled { break }
        }

        // Left: this letter's own edge when a letter whose panel overlaps
        // it vertically stands to its left, else the figure's.
        var panels: [String: PaperFigureRect] = [:]
        for anchor in anchors {
            let a = anchor.rect
            let top = tops[anchor.label] ?? figure.y
            let bottom = bottoms[anchor.label] ?? figureBottom
            let right = rights[anchor.label] ?? figureRight
            let hasLetterToTheLeft = anchors.contains { other in
                other != anchor && other.rect.x + other.rect.width <= a.x && overlapsVertically(anchor, other)
            }
            let left = hasLetterToTheLeft ? max(figure.x, a.x - gutter) : figure.x
            let rect = PaperFigureRect(
                x: max(figure.x, left),
                y: max(figure.y, top),
                width: min(figureRight, right) - max(figure.x, left),
                height: min(figureBottom, bottom) - max(figure.y, top)
            )
            if rect.isValid { panels[anchor.label] = rect }
        }
        return panels
    }

    // MARK: - Together

    /// The figure's panels by letter, trimmed to the ink inside each when a
    /// mask is given. Empty when the text layer carries no panel letters.
    static func panelRects(
        in figure: PaperFigureRect,
        on page: PDFPage,
        mask: PaperFigureRectRefiner.PageInkMask? = nil
    ) -> [String: PaperFigureRect] {
        let anchors = panelAnchors(from: textLines(in: figure, on: page))
        let partitioned = partition(anchors, within: figure)
        guard let mask else { return partitioned }
        var trimmed: [String: PaperFigureRect] = [:]
        for (label, rect) in partitioned {
            // Trimming only: growing a panel could reach into the one beside
            // it. `sharesPageWithOtherFigures` is true so the sole-figure
            // repair never widens a panel to its whole band.
            let refined = PaperFigureRectRefiner.refined(
                rect,
                with: mask,
                sharesPageWithOtherFigures: true,
                allowsGrowth: false
            )
            trimmed[label] = refined.flatMap { clipped($0, to: rect) } ?? rect
        }
        return trimmed
    }

    /// One panel of the figure, by its printed letter in either case, or nil
    /// when the text layer does not place it.
    static func panelRect(
        labelled label: String,
        in figure: PaperFigureRect,
        on page: PDFPage,
        mask: PaperFigureRectRefiner.PageInkMask? = nil
    ) -> PaperFigureRect? {
        guard let letter = leadingPanelLetter(of: label) else { return nil }
        return panelRects(in: figure, on: page, mask: mask)[letter]
    }

    // MARK: - The figure's own words

    /// At most this many printed lines are kept for a figure: enough for the
    /// axis titles, legend keys and condition labels of a six-panel figure,
    /// not a table's every cell.
    static let printedTextLineLimit = 40

    /// What the figure prints in words, in reading order: its axis titles with
    /// their units, its legend keys, the labels of its conditions and
    /// treatment bars, its significance marks. Panel letters and lines that
    /// are numbers alone — tick labels — are left out; a line printed twice
    /// (two panels sharing an x axis, "Time (min) Time (min)") is kept once.
    /// This is what the walkthrough writer is handed so a step can say what
    /// an axis is without seeing the picture (product owner, 2026-09-20: "it would
    /// be nice for you to show, like, x axis is this, y axis is this").
    static func printedText(from lines: [TextLine]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for line in lines {
            guard var text = printedLine(line.text) else { continue }
            let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if tokens.count >= 2, tokens.count % 2 == 0,
               Array(tokens[..<(tokens.count / 2)]) == Array(tokens[(tokens.count / 2)...]) {
                text = tokens[..<(tokens.count / 2)].joined(separator: " ")
            }
            guard seen.insert(text.lowercased()).inserted else { continue }
            result.append(text)
            if result.count == printedTextLineLimit { break }
        }
        return result
    }

    /// `text` collapsed to one line, or nil when it says nothing a reader
    /// needs told: empty, panel letters alone ("a", "a b", "(C)"), or numbers
    /// alone ("1.4", "0 10 20 30", "−5%", "n = 6" keeps its letter).
    static func printedLine(_ text: String) -> String? {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return nil }
        if tokens.allSatisfy({ leadingPanelLetter(of: $0) != nil && $0.count <= 3 }) { return nil }
        let numeric = CharacterSet(charactersIn: "0123456789.,+-−–%×·:/")
        if tokens.allSatisfy({ $0.unicodeScalars.allSatisfy(numeric.contains) }) { return nil }
        return tokens.joined(separator: " ")
    }

    /// The words printed inside `figure` on `page`; empty for a raster figure
    /// or a scan, whose text layer holds nothing there.
    static func printedText(in figure: PaperFigureRect, on page: PDFPage) -> [String] {
        printedText(from: textLines(in: figure, on: page))
    }

    // MARK: - Reading a paper's figures

    /// What one figure's text layer says: the panel letters it prints and the
    /// words inside it.
    struct TextLayerReading: Equatable, Sendable {
        var panelLabels: [String] = []
        var printedText: [String] = []
    }

    /// Where one figure is, as much as the text layer needs to find it: the
    /// page, the printed caption the crop is anchored on, and the rectangle
    /// the vision analysis measured when there is one (used only when the
    /// page's own crop around the caption is not found).
    struct FigureLocation: Sendable {
        var id: String
        var label: String
        var pageIndex: Int
        var caption: String
        var measuredRect: PaperFigureRect?
    }

    /// Each figure's text-layer reading, by figure id: its panel letters and
    /// the words printed inside it. Figures on a page the document cannot
    /// render, or whose crop cannot be found, are absent. The letters need no
    /// ink mask, since which panels a figure has does not depend on trimming
    /// their boxes. Both apps read a paper this way: the Mac from its figure
    /// index, the phone from the figures synced with the source.
    static func textLayer(for figures: [FigureLocation], in document: PDFDocument) -> [String: TextLayerReading] {
        guard !figures.isEmpty else { return [:] }
        let labelsPerPage = Dictionary(grouping: figures, by: \.pageIndex).mapValues { Set($0.map(\.label)).count }
        var result: [String: TextLayerReading] = [:]
        // A PDFPage holds its document weakly and PDFKit's text scanner
        // dereferences it; ARC may release `document` after its last call
        // while the last page is still being read. Hold it to the end.
        withExtendedLifetime(document) {
            for figure in figures {
                guard let page = document.page(at: figure.pageIndex) else { continue }
                guard let crop = PaperFigureRectRefiner.displayedFigureCrop(
                    forCaption: figure.caption,
                    measured: figure.measuredRect,
                    on: page,
                    sharesPageWithOtherFigures: (labelsPerPage[figure.pageIndex] ?? 1) > 1
                ) else { continue }
                let lines = textLines(in: crop, on: page)
                let letters = partition(panelAnchors(from: lines), within: crop).keys.sorted()
                result[figure.id] = TextLayerReading(panelLabels: letters, printedText: printedText(from: lines))
            }
        }
        return result
    }

    #if os(macOS)
    /// The panel letters each figure prints, by figure id, read off the PDF's
    /// text layer: what the writer is told a figure has and what the validator
    /// holds it to. Figures on a page the document cannot render, or whose
    /// text layer carries no letters, are absent.
    static func panelLabels(for figures: [PaperFigureRecord], pdfPath: String) -> [String: [String]] {
        textLayer(for: figures, pdfPath: pdfPath).compactMapValues { $0.panelLabels.isEmpty ? nil : $0.panelLabels }
    }

    /// `textLayer(for:in:)` over the Mac's figure index, one document open.
    static func textLayer(for figures: [PaperFigureRecord], pdfPath: String) -> [String: TextLayerReading] {
        // A book chapter's path names its pages of the book's file (`SourcePDFPages`).
        guard !figures.isEmpty, let document = SourcePDFPages.document(atStored: pdfPath) else { return [:] }
        return textLayer(
            for: figures.map {
                FigureLocation(
                    id: $0.id,
                    label: $0.figureLabel,
                    pageIndex: $0.pageIndex,
                    caption: $0.caption,
                    measuredRect: $0.analysis?.figureRect
                )
            },
            in: document
        )
    }
    #endif

    /// The trimmed rectangle cannot leave the partition it was trimmed inside.
    private static func clipped(_ rect: PaperFigureRect, to bounds: PaperFigureRect) -> PaperFigureRect? {
        let x = max(rect.x, bounds.x)
        let y = max(rect.y, bounds.y)
        let right = min(rect.x + rect.width, bounds.x + bounds.width)
        let bottom = min(rect.y + rect.height, bounds.y + bounds.height)
        let result = PaperFigureRect(x: x, y: y, width: right - x, height: bottom - y)
        return result.isValid ? result : nil
    }
}
#endif
