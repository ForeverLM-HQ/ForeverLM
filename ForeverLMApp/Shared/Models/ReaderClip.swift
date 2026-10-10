import Foundation

/// A clip: a box the learner drew round part of a PDF page in the Reader (a
/// figure, a panel, a table, an equation), kept with where it came from, so it
/// can go on the Canvas and still open the page it was cut from
/// (docs/knowledge-map-design.md, "Clips").
///
/// A clip is a mark on a picture (`SourceHighlight.isPictureOnly`) whose one
/// picture is the page region itself, addressed as a `SourceImageReference`:
/// `foreverlm://image/<sourceID>/page/<n>?crop=x,y,w,h`. That is a kind of mark
/// every client already stores, syncs and lists, and the address carries no
/// pixels: every Mac draws the clip again from the PDF it holds, as the chat
/// draws a figure it shows. So a clip needs no schema bump and no image file,
/// and the learner's note on it is the mark's note.
enum ReaderClip {
    /// The page region a mark clips, or nil for every other mark: a passage,
    /// a web page's picture, a mark with more than one picture.
    static func reference(of highlight: SourceHighlight) -> SourceImageReference? {
        guard highlight.isPictureOnly, highlight.imageAnchors.count == 1,
              let reference = SourceImageReference(urlString: highlight.imageAnchors[0].src),
              case .page = reference.location, reference.crop != nil else { return nil }
        return reference
    }

    static func isClip(_ highlight: SourceHighlight) -> Bool {
        reference(of: highlight) != nil
    }

    /// A passage the learner marked in a paper or article, as a card on a
    /// canvas: its words, with the paper it came from one click away
    /// (Heptabase's highlight card; docs/knowledge-map-design.md,
    /// "Passages on the Canvas"). Only a mark with words and no pictures.
    static func isPassage(_ highlight: SourceHighlight) -> Bool {
        highlight.imageAnchors.isEmpty && SourceHighlight.hasWords(highlight.quote)
    }

    /// The one-based page a passage sits on, when it was marked in a PDF.
    static func passagePage(of highlight: SourceHighlight) -> Int? {
        highlight.pdfAnchor.map { $0.pageIndex + 1 }
    }

    /// The one-based page a clip was cut from.
    static func page(of highlight: SourceHighlight) -> Int? {
        guard let reference = reference(of: highlight), case .page(let page) = reference.location else { return nil }
        return page
    }

    /// What a clip is called: the figure it was matched to, else its page.
    static func title(of highlight: SourceHighlight) -> String {
        let alt = highlight.imageAnchors.first?.alt ?? ""
        if !alt.isEmpty { return alt }
        return page(of: highlight).map { "Page \($0)" } ?? "Clip"
    }

    /// The clip's width over its height, from the pixels it was cut at; nil
    /// when they were not known.
    static func aspect(of highlight: SourceHighlight) -> Double? {
        guard let anchor = highlight.imageAnchors.first, anchor.width > 0, anchor.height > 0 else { return nil }
        return Double(anchor.width) / Double(anchor.height)
    }

    /// The clip under the id its source is shown by: under generation 2 a
    /// mark is kept on the source's wire id, which a team's copy shares.
    static func filed(_ highlight: SourceHighlight, under sourceID: String) -> SourceHighlight {
        guard highlight.sourceID != sourceID else { return highlight }
        return SourceHighlight(
            id: highlight.id,
            sourceID: sourceID,
            quote: highlight.quote,
            note: highlight.note,
            color: highlight.color,
            anchor: highlight.anchor,
            pdfAnchor: highlight.pdfAnchor,
            imageAnchors: highlight.imageAnchors,
            chatSessionID: highlight.chatSessionID,
            references: highlight.references,
            publicationUpdate: highlight.publicationUpdate,
            publicationUpdateAt: highlight.publicationUpdateAt,
            createdAt: highlight.createdAt,
            updatedAt: highlight.updatedAt
        )
    }

    /// The mark a new clip is saved as. The passage is empty, since a clip is
    /// a picture; `title` is what the notes list and the Canvas call it.
    static func highlight(
        id: String = SourceHighlight.newID(),
        sourceID: String,
        page: Int,
        crop: PaperFigureRect,
        title: String,
        pixelWidth: Int,
        pixelHeight: Int,
        note: String = "",
        at date: Date = Date()
    ) -> SourceHighlight {
        let reference = SourceImageReference(sourceID: sourceID, location: .page(page), crop: crop)
        return SourceHighlight(
            id: id,
            sourceID: sourceID,
            quote: "",
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            color: .default,
            anchor: ReaderTextAnchor(exact: ""),
            pdfAnchor: nil,
            imageAnchors: [ReaderImageAnchor(src: reference.urlString, alt: title, width: pixelWidth, height: pixelHeight)],
            createdAt: date,
            updatedAt: date
        )
    }
}

// MARK: - What a box is of

/// A figure on a page as the paper's figure index places it: its label, its
/// caption, its rectangle and its panels' rectangles, each normalized to the
/// page with a top-left origin (`PaperFigureRect`).
struct ReaderClipFigureRegion: Equatable, Sendable {
    struct Panel: Equatable, Sendable {
        /// The panel as the reader names it: "B", or a named panel's name.
        let name: String
        let rect: PaperFigureRect
    }

    let figureLabel: String
    let caption: String
    let rect: PaperFigureRect
    var panels: [Panel] = []
}

/// Matches a box the learner drew to the figure, or the panels, it holds.
/// Deterministic geometry over the figure index: nothing here asks a model,
/// so a clip's name never changes between two Macs or two tries.
enum ReaderClipMatch {
    struct Result: Equatable, Sendable {
        /// "Figure 2", "Figure 2B", "Figure 2B–D".
        let label: String
        let figureLabel: String
        let panels: [String]
        /// The caption's words after its label, when it has any.
        let captionTitle: String?
    }

    /// The figure whose rectangle holds most of the box (at least 60% of it),
    /// and the panels the box takes in: each one it covers at least 60% of,
    /// or the one it sits inside. A box round the whole figure, or round
    /// every panel, is the figure.
    static func match(_ box: PaperFigureRect, in regions: [ReaderClipFigureRegion]) -> Result? {
        let boxArea = area(box)
        guard boxArea > 0 else { return nil }
        let scored = regions.map { (region: $0, share: overlap(box, $0.rect) / boxArea) }
        guard let best = scored.filter({ $0.share >= 0.6 }).max(by: { $0.share < $1.share })?.region else { return nil }
        let figureCovered = overlap(box, best.rect) / max(area(best.rect), 1e-9)
        var names = best.panels.filter { overlap(box, $0.rect) / max(area($0.rect), 1e-9) >= 0.6 }.map(\.name)
        if names.isEmpty, let inside = best.panels.first(where: { overlap(box, $0.rect) / boxArea >= 0.7 }) {
            names = [inside.name]
        }
        if figureCovered >= 0.8 || names.count == best.panels.count { names = [] }
        return Result(
            label: label(figure: best.figureLabel, panels: names),
            figureLabel: best.figureLabel,
            panels: names,
            captionTitle: PaperFigureCaptionTitle.title(from: best.caption)
        )
    }

    /// Where a click on the page snaps the box: the smallest panel under the
    /// pointer, or the figure when there is no panel there; a second click
    /// on the panel the box already is grows it to the whole figure. Nil when
    /// no indexed figure is under the pointer.
    static func snap(x: Double, y: Double, in regions: [ReaderClipFigureRegion], current: PaperFigureRect?) -> PaperFigureRect? {
        func contains(_ rect: PaperFigureRect) -> Bool {
            x >= rect.x && x <= rect.x + rect.width && y >= rect.y && y <= rect.y + rect.height
        }
        guard let figure = regions.filter({ contains($0.rect) }).min(by: { area($0.rect) < area($1.rect) }) else { return nil }
        let panel = figure.panels.filter { contains($0.rect) }.min { area($0.rect) < area($1.rect) }
        if let panel, panel.rect != current { return panel.rect }
        return figure.rect
    }

    /// The name a clip is saved under: the figure and its caption's title,
    /// or the page when the box holds no indexed figure.
    static func title(for result: Result?, page: Int) -> String {
        guard let result else { return "Page \(page)" }
        guard let caption = result.captionTitle, !caption.isEmpty else { return result.label }
        let full = "\(result.label) · \(caption)"
        return full.count <= 140 ? full : String(full.prefix(139)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// "Figure 2" with its panels: one letter joined on ("Figure 2B"), a run
    /// of letters as a range ("Figure 2B–D"), letters apart listed
    /// ("Figure 2B, D"), and named panels after a dot ("Figure 2 · DESIGN").
    static func label(figure: String, panels: [String]) -> String {
        guard !panels.isEmpty else { return figure }
        let letters = panels.compactMap { $0.count == 1 && $0.first?.isLetter == true ? $0.uppercased().first : nil }
        guard letters.count == panels.count else { return figure + " · " + panels.joined(separator: ", ") }
        let sorted = letters.sorted()
        let run = zip(sorted, sorted.dropFirst()).allSatisfy { pair in
            (pair.1.asciiValue ?? 0) == (pair.0.asciiValue ?? 0) + 1
        }
        if sorted.count == 1 { return figure + String(sorted[0]) }
        if run, sorted.count >= 3, let first = sorted.first, let last = sorted.last { return figure + "\(first)–\(last)" }
        return figure + sorted.map(String.init).joined(separator: ", ")
    }

    static func area(_ rect: PaperFigureRect) -> Double {
        max(0, rect.width) * max(0, rect.height)
    }

    static func overlap(_ a: PaperFigureRect, _ b: PaperFigureRect) -> Double {
        let width = min(a.x + a.width, b.x + b.width) - max(a.x, b.x)
        let height = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
        return width > 0 && height > 0 ? width * height : 0
    }
}

// MARK: - Dragging a clip

/// A clip on the pasteboard, as the Reader's Clip tool drags it: the page
/// region and its name, so whatever it is dropped on (the Canvas) knows
/// where it came from. `highlightID` is set once the clip is saved, so a
/// saved clip dropped again is placed rather than saved twice.
struct StudioClipTransfer: Codable, Equatable, Sendable {
    var sourceID: String
    /// One-based page of the source's own PDF.
    var page: Int
    var crop: PaperFigureRect
    var title: String
    var pixelWidth: Int
    var pixelHeight: Int
    var highlightID: String?

    /// A saved clip as it drags: from the Canvas's tray back onto the plane.
    init?(clip highlight: SourceHighlight) {
        guard let reference = ReaderClip.reference(of: highlight), let crop = reference.crop,
              case .page(let page) = reference.location, let anchor = highlight.imageAnchors.first else { return nil }
        self.init(
            sourceID: highlight.sourceID,
            page: page,
            crop: crop,
            title: ReaderClip.title(of: highlight),
            pixelWidth: anchor.width,
            pixelHeight: anchor.height,
            highlightID: highlight.id
        )
    }

    /// A passage as it drags: from the Reader's notes or the Canvas's tray
    /// onto the plane. It names a mark that exists (`highlightID`); there is
    /// no page region (`page` 0), so nothing new is ever saved from it.
    init?(passage highlight: SourceHighlight) {
        guard ReaderClip.isPassage(highlight) else { return nil }
        self.init(
            sourceID: highlight.sourceID,
            page: 0,
            crop: PaperFigureRect(x: 0, y: 0, width: 1, height: 1),
            title: highlight.quote,
            pixelWidth: 0,
            pixelHeight: 0,
            highlightID: highlight.id
        )
    }

    /// Whether this names a passage mark rather than a page region.
    var isPassage: Bool { page == 0 }

    init(sourceID: String, page: Int, crop: PaperFigureRect, title: String, pixelWidth: Int, pixelHeight: Int, highlightID: String?) {
        self.sourceID = sourceID
        self.page = page
        self.crop = crop
        self.title = title
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.highlightID = highlightID
    }

    var imageReference: SourceImageReference {
        SourceImageReference(sourceID: sourceID, location: .page(page), crop: crop)
    }

    /// The mark this clip is saved as.
    func highlight(at date: Date = Date()) -> SourceHighlight {
        ReaderClip.highlight(
            id: highlightID ?? SourceHighlight.newID(),
            sourceID: sourceID,
            page: page,
            crop: crop,
            title: title,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            at: date
        )
    }
}
