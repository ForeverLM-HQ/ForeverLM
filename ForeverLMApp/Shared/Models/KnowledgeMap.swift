import Foundation
import CoreGraphics

/// A canvas: one zoomable plane over the whole library (docs/knowledge-map-design.md).
/// The learner has as many as they make, each an item in the Space beside
/// their pages and sites ("Canvases in the Space").
///
/// The learner places cards on it, draws regions around them and arrows between
/// them; nothing ForeverLM does moves a card the learner placed. A lens is
/// ForeverLM's temporary view of the same cards — grouped, or laid out on two
/// axes — which shows until the learner presses Keep (and the lens's spots
/// become their placements) or goes back to their own map.
///
/// An item on the map is named by an `ItemRef`: `source:<id>`, `doc:<id>` (a
/// Doc or anything else a notebook made: a site, an animation, an audio
/// overview, a reading), `idea:<id>`, `clip:<highlightID>` (a box cut out of
/// a PDF page in the Reader, `ReaderClip`), `page:<sourceID>:<n>` (one
/// rendered page of a PDF source, drawn from the PDF itself, never saved),
/// `canvas:<canvasID>` (a shortcut card to another canvas), `chat:<sessionID>`
/// (a chat) or `picture:<imageID>` (an image from the Images library).
/// The layout is one synced preference row per canvas (`map.layout.<mapID>`),
/// merged entry by entry when two Macs changed it before syncing. The row is
/// the canvas: it also carries its name, when it was made and whether it is
/// in Trash, so every row there is lists one canvas.
enum KnowledgeMap {
    /// The renderer's card size in world units; the lens layout spaces cards
    /// by it, so a lens never stacks two cards on one another.
    static let cardWidth: Double = 240
    static let cardHeight: Double = 120
    /// A clip's card is as wide as any card and as tall as its picture at that
    /// width, within reason, over a foot for its name and the learner's note
    /// (the renderer's `CLIP_FOOT`).
    static let clipFootHeight: Double = 46
    /// What a figure clip's foot grows by to show the figure's printed
    /// caption under its name (the renderer's `CAPTION_ROOM`).
    static let clipCaptionHeight: Double = 32

    /// A passage's card: the quoted words over a foot naming the paper.
    static let passageHeight: Double = 168

    /// A folded card draws as its title line only (the renderer's `FOLD_H`).
    static let foldedCardHeight: Double = 40

    /// How wide a card may be made (`Placement.w`), and how tall (`Placement.h`).
    static let cardWidthRange: ClosedRange<Double> = 160...720
    static let cardHeightRange: ClosedRange<Double> = foldedCardHeight...2000

    /// A picture card's height: the picture whole at the card's width, as a
    /// clip's is, within reason, with no foot under it. 160 until the
    /// picture's shape is known.
    static func pictureHeight(aspect: Double?) -> Double {
        let picture = aspect.map { cardWidth / max($0, 0.05) } ?? 160
        return min(max(picture, 70), 420)
    }

    // MARK: A paper as its page, a note under a card, a mind map's nodes
    // (docs/knowledge-map-design.md, "What Sapience showed (2026-10-10): the
    // contract"). The renderer computes the same numbers by the same formulas
    // (`pageFaceHeight`, `annotationHeight` and `treeNodeSize` in
    // `knowledge-map.js`), so a card is as tall where it is drawn as where the
    // Mac set it down.

    /// The foot a page face keeps under the page: its title (two lines) and
    /// its byline (one).
    static let pageFaceFootHeight: Double = 70

    /// A page's width over its height until the PDF has been read: US Letter.
    static let defaultPageAspect: Double = 0.7727

    /// A page face's height: the page at the card's width (within half and
    /// two and seven tenths of the width, rounded) over the foot.
    static func pageFaceHeight(aspect: Double?, width: Double) -> Double {
        let shape = aspect.flatMap { $0 > 0 ? $0 : nil } ?? defaultPageAspect
        let page = min(max(width / shape, width * 0.5), width * 2.7)
        return page.rounded() + pageFaceFootHeight
    }

    /// The most characters of words a card carries under it on a canvas.
    static let annotationLimit = 600

    /// The most lines of them the card draws.
    static let annotationLineLimit = 12

    /// The words as a placement stores them: trimmed, at most
    /// `annotationLimit` characters, and nothing for an empty text.
    static func annotation(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = String(trimmed.prefix(annotationLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
        return capped.isEmpty ? nil : capped
    }

    /// The room a card's annotation takes at the bottom of the card: nothing
    /// for no words, else each paragraph (a line of the text) takes the lines
    /// its characters fill at 6.5 points apiece across the card less its 28
    /// points of padding (at least one), at most `annotationLineLimit` lines
    /// in all, 16 points each over 10 points of padding.
    static func annotationHeight(_ text: String?, width: Double) -> Double {
        guard let text, !text.isEmpty else { return 0 }
        var lines = 0
        for paragraph in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            lines += max(1, Int((Double(paragraph.count) * 6.5 / (width - 28)).rounded(.up)))
        }
        return 10 + Double(min(lines, annotationLineLimit)) * 16
    }

    /// How large a mind map draws a node: its words in one box, 7 points a
    /// character (a root's 8.6) across the box less its padding, wrapped to at
    /// most four lines, the root a little larger than the rest. A node whose
    /// words just fill one line is one line: the division is not allowed the
    /// rounding noise that would make it a hair over one (14 characters of a
    /// root's, say), and the renderer takes the same care.
    static func treeNodeSize(title: String, role: KnowledgeMapTreeNodeRole) -> (w: Double, h: Double) {
        let isRoot = role == .root
        let charW = isRoot ? 8.6 : 7.0
        let padX = isRoot ? 18.0 : 12.0, padY = isRoot ? 12.0 : 7.0
        let lineH = isRoot ? 21.0 : 17.0
        let minW = isRoot ? 120.0 : 60.0, maxW = isRoot ? 280.0 : 220.0
        let textW = Double(title.count) * charW
        let w = min(max(textW + 2 * padX, minW), maxW)
        let lines = min(4, max(1, Int((textW / (w - 2 * padX) - 1e-9).rounded(.up))))
        return (w.rounded(), (2 * padY + Double(lines) * lineH).rounded())
    }

    /// Whether an Idea's title is a question: it ends with `?` or `？`.
    static func isQuestion(_ title: String) -> Bool {
        guard let last = title.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return last == "?" || last == "？"
    }

    /// An arrow's end may be a region instead of a card: `region:<regionID>`.
    static let regionRefPrefix = "region:"

    static func regionRef(_ regionID: String) -> String { regionRefPrefix + regionID }

    /// The region an arrow end names; nil for a card's ref.
    static func regionID(fromRef ref: String) -> String? {
        guard ref.hasPrefix(regionRefPrefix) else { return nil }
        let id = String(ref.dropFirst(regionRefPrefix.count))
        return id.isEmpty ? nil : id
    }

    /// A page card's height when the page's shape is not known yet: US Letter
    /// at the card's width, over the foot naming it.
    static let defaultPageHeight: Double = 310 + clipFootHeight

    /// The most pages one expansion of a PDF sets down (`pageRange`), so a
    /// book is not laid across the plane by accident; ask for another range
    /// for the rest.
    static let maximumPagesPerExpansion = 60

    /// A page card's height: the page at the card's width over its foot,
    /// like a clip, but never cropped to a smaller picture than the page.
    static func pageHeight(aspect: Double?) -> Double {
        guard let aspect, aspect > 0 else { return defaultPageHeight }
        return min(max(cardWidth / aspect, 120), 640) + clipFootHeight
    }

    /// The ref of one page of a PDF source.
    static func pageRef(sourceID: String, page: Int) -> String {
        ItemRef(kind: .page, id: "\(sourceID):\(page)").description
    }

    /// The pages `spec` names within `pageCount`: "3", "2-5", "1,4,7-9" or
    /// "all", one-based, in order, each once, clamped to the document. Nil
    /// for a spec that names no page of it.
    static func pageRange(_ spec: String?, pageCount: Int) -> [Int]? {
        guard pageCount > 0 else { return nil }
        let text = (spec ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.isEmpty || text == "all" { return Array(1...pageCount) }
        var seen: Set<Int> = []
        var pages: [Int] = []
        for part in text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " }) {
            let ends = part.split(separator: "-", omittingEmptySubsequences: false)
                .map { Int($0.trimmingCharacters(in: .whitespaces)) }
            let low: Int, high: Int
            switch ends.count {
            case 1:
                guard let a = ends[0] else { return nil }
                low = a; high = a
            case 2:
                guard let a = ends[0], let b = ends[1] else { return nil }
                low = min(a, b); high = max(a, b)
            default:
                return nil
            }
            guard high >= 1, low <= pageCount else { continue }
            for page in max(low, 1)...min(high, pageCount) where seen.insert(page).inserted { pages.append(page) }
        }
        return pages.isEmpty ? nil : pages
    }

    static func clipHeight(aspect: Double?, captioned: Bool = false) -> Double {
        let picture = aspect.map { cardWidth / max($0, 0.05) } ?? 160
        return min(max(picture, 70), 420) + clipFootHeight + (captioned ? clipCaptionHeight : 0)
    }

    /// The first canvas: the one Canvas there was before canvases were
    /// listed in the Space (2026-10-07). Its row is listed like any other;
    /// it may carry no name and no date, having been written before either.
    static let firstCanvasID = "library"
    static let preferenceKeyPrefix = "map."
    static let layoutKeyPrefix = "map.layout."
    /// What every canvas made in the Space is called by: `cnv-` and a
    /// lowercased UUID.
    static let canvasIDPrefix = "cnv-"
    /// The name of a canvas that was never given one: the first canvas.
    static let unnamedCanvasName = "Canvas"
    /// The name a new canvas starts with, as a new page starts "Untitled".
    static let newCanvasName = "Untitled canvas"
    /// The canvas's glyph: its rows in the Space, its tab and its menus.
    static let symbolName = "rectangle.3.group"

    static func newCanvasID() -> String {
        canvasIDPrefix + UUID().uuidString.lowercased()
    }

    static func layoutPreferenceKey(mapID: String) -> String {
        layoutKeyPrefix + mapID
    }

    static func mapID(fromLayoutKey key: String) -> String? {
        guard key.hasPrefix(layoutKeyPrefix) else { return nil }
        let id = String(key.dropFirst(layoutKeyPrefix.count))
        return id.isEmpty ? nil : id
    }

    /// What kind of record an item ref names.
    enum ItemKind: String, Codable, Sendable {
        case source
        case doc
        case idea
        /// A clip cut out of a page in the Reader, by its highlight's id.
        case clip
        /// One rendered page of a PDF source: `page:<sourceID>:<n>`.
        case page
        /// A shortcut card to another canvas: `canvas:<canvasID>`. Opening it
        /// opens that canvas.
        case canvas
        /// A chat as a card: `chat:<reviewSessionID>`.
        case chat
        /// An image from the Images library: `picture:<imageID>`.
        case picture
    }

    struct ItemRef: Hashable, Codable, Sendable, CustomStringConvertible {
        let kind: ItemKind
        let id: String

        init(kind: ItemKind, id: String) {
            self.kind = kind
            self.id = id
        }

        /// Parses `source:<id>`, `doc:<id>`, `idea:<id>`, `clip:<id>`,
        /// `page:<sourceID>:<n>`, `canvas:<id>`, `chat:<id>` or `picture:<id>`;
        /// anything else is nil (a `region:<id>` is an arrow's end, not a card).
        init?(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = trimmed.firstIndex(of: ":"),
                  let kind = ItemKind(rawValue: String(trimmed[..<colon])) else { return nil }
            let id = String(trimmed[trimmed.index(after: colon)...])
            guard !id.isEmpty else { return nil }
            self.kind = kind
            self.id = id
        }

        var description: String { "\(kind.rawValue):\(id)" }

        /// For a page card, the source it is a page of and its one-based page
        /// number; nil for every other kind. A source id may hold colons, so
        /// the number is what follows the last one.
        var pageParts: (sourceID: String, page: Int)? {
            guard kind == .page, let colon = id.lastIndex(of: ":"),
                  let page = Int(id[id.index(after: colon)...]), page >= 1 else { return nil }
            let sourceID = String(id[..<colon])
            return sourceID.isEmpty ? nil : (sourceID, page)
        }

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let ref = ItemRef(raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a map item ref: \(raw)"))
            }
            self = ref
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(description)
        }
    }
}

/// A node of a mind map: the card the map hangs from (`root`: no branch leads
/// to it), a card with branches of its own (`branch`), or one with none
/// (`leaf`).
enum KnowledgeMapTreeNodeRole: String, Sendable {
    case root, branch, leaf
}

/// What this Mac has read of a source's PDF to draw a paper as its page: how
/// many pages it has (0 once looked at and found to have none) and its first
/// page's width over its height.
struct KnowledgeMapPageFace: Equatable, Sendable {
    var pageCount: Int
    var aspect: Double?
}

// MARK: - The learner's layout

/// Where the learner put things. Each entry carries the time it was last
/// written (`at`, seconds since 1970), and a removal leaves a tombstone with
/// its own time, so two copies of the row merge entry by entry: the newer
/// write of each placement, region and arrow wins, and a removal beats an
/// older write of the same entry.
struct KnowledgeMapLayout: Codable, Equatable, Sendable {
    struct Placement: Codable, Equatable, Sendable {
        var x: Double
        var y: Double
        var at: Double
        /// The card's width; nil is the usual 240
        /// (`KnowledgeMap.cardWidthRange` bounds it).
        var w: Double? = nil
        /// The card's height; nil is the kind's own (auto for an Idea).
        var h: Double? = nil
        /// Whether the card is folded to its title line. Nil and false are
        /// the same.
        var folded: Bool? = nil
        /// A tint, one of `KnowledgeMapModel.regionColors`; nil is the kind's
        /// own.
        var color: String? = nil
        /// The card is a **page face**: page `page` (one-based) of its source's
        /// PDF drawn as the card, its title and authors under it. Nil is the
        /// usual face. It means something only for a `source:` card whose PDF
        /// this Mac holds; on a Mac without it the card draws its usual face
        /// and keeps the field.
        var page: Int? = nil
        /// The learner's words about the card on this canvas, "why it is
        /// here": at most `KnowledgeMap.annotationLimit` characters, trimmed,
        /// never empty. Every kind of card but an Idea, whose own note holds
        /// its words. They belong to the card's spot on this canvas, not to
        /// what the card stands for.
        var annotation: String? = nil
        /// An Idea drawn as words on the plane, with no sticky note. Nil and
        /// false are the same.
        var plain: Bool? = nil
        /// A question Idea (`KnowledgeMap.isQuestion`) marked answered on this
        /// canvas, as a colour is the canvas's: the Idea itself is not
        /// touched. Nil and false are the same.
        var answered: Bool? = nil

        var isFolded: Bool { folded == true }
        var isPlain: Bool { plain == true }
        var isAnswered: Bool { answered == true }
    }

    struct Region: Codable, Equatable, Sendable {
        var name: String
        var x: Double
        var y: Double
        var w: Double
        var h: Double
        var color: String
        var at: Double
        /// The notebook this region is the frame of, when the learner set a
        /// notebook down (or named a region after one): the frame takes the
        /// notebook's name, draws the notebook's sources and Docs that are not
        /// placed anywhere yet in it, and reads as the notebook and its
        /// takeaways when zoomed out.
        var notebookID: String? = nil
        /// Whether the learner folded the region up: it draws as its name and
        /// a count, and the cards inside it are not drawn, though they stay
        /// placed exactly where they are, in the layout and in the row. Nil
        /// and false are the same (a region from before this existed).
        var collapsed: Bool? = nil
        /// Whether the region is locked: its cards cannot be dragged, nor the
        /// region moved or resized, until it is unlocked. Nil and false are
        /// the same.
        var locked: Bool? = nil
        /// How its cards are laid out: `"tree"` is a mind map, laid out by the
        /// renderer from the tree edges among its cards; nil is free.
        var layout: String? = nil

        var isCollapsed: Bool { collapsed == true }
        var isLocked: Bool { locked == true }
        var isTree: Bool { layout == KnowledgeMapLayout.treeLayout }
    }

    struct Edge: Codable, Equatable, Sendable {
        /// A card's ref, or `region:<regionID>`.
        var from: String
        var to: String
        var label: String
        var at: Double
        /// `"curve"` (nil), `"straight"` or `"elbow"`.
        var route: String? = nil
        var dashed: Bool? = nil
        /// Where the arrowhead is: `"end"` (nil), `"both"` or `"none"`.
        var heads: String? = nil
        /// A tint as `#RRGGBB`; nil is the usual arrow colour.
        var color: String? = nil
        /// A mind-map branch, parent to child: drawn as a branch, not an
        /// arrow.
        var tree: Bool? = nil
        /// Which side of an argument the arrow is on, as `KnowledgeMapEdgeStance`
        /// names it (`"supports"` or `"contradicts"`): drawn green or red unless
        /// the arrow has a `color` of its own. Nil is none.
        var stance: String? = nil

        var isTree: Bool { tree == true }
        var isDashed: Bool { dashed == true }
        /// The stance, when this build knows the one stored.
        var knownStance: KnowledgeMapEdgeStance? { stance.flatMap(KnowledgeMapEdgeStance.init(rawValue:)) }
    }

    /// The value of a region's `layout` for a mind map.
    static let treeLayout = "tree"

    /// The format's version; a row from a later format is read as empty
    /// rather than half-understood.
    static let currentVersion = 1
    /// How long a tombstone is kept. A Mac offline for longer than this may
    /// bring back an entry the learner removed meanwhile.
    static let tombstoneLifetime: TimeInterval = 90 * 24 * 3600

    var version: Int = KnowledgeMapLayout.currentVersion
    /// Keyed by item ref (`source:<id>`, `idea:<id>`).
    var placements: [String: Placement] = [:]
    var regions: [String: Region] = [:]
    var edges: [String: Edge] = [:]
    /// Tombstones: `p:<ref>`, `r:<regionID>`, `e:<edgeID>`, by time removed.
    var removed: [String: Double] = [:]

    // MARK: The canvas itself

    /// The canvas's name as the learner gave it, with when it was written;
    /// nil for a canvas never named (the first canvas reads "Canvas").
    var name: NameMark?
    /// When the canvas was made, in seconds since 1970; nil for the first
    /// canvas, written before canvases had a date.
    var created: Double?
    /// Whether the canvas is in Trash, with when that was written; nil for a
    /// canvas never put there. Restoring writes a mark with no `since`.
    var trash: TrashMark?
    /// The notebook this canvas belongs to, with when that was written
    /// (product owner, 2026-10-09: "within a notebook, I want a canvas where I
    /// explore certain ideas"). A canvas is still a plane over the whole
    /// library; the mark says where it is listed and opened from. Nil for a
    /// canvas of no notebook; unlinking writes a mark with no `id`.
    var notebook: NotebookMark?

    struct NotebookMark: Codable, Equatable, Sendable {
        /// The notebook's id; nil once the canvas was taken out of it.
        var id: String?
        var at: Double
    }

    struct NameMark: Codable, Equatable, Sendable {
        var text: String
        var at: Double
    }

    struct TrashMark: Codable, Equatable, Sendable {
        /// When the learner put the canvas in Trash; nil once restored.
        var since: Double?
        var at: Double
    }

    init() {}

    /// The latest time anything on the canvas was written: its last
    /// activity in the Space's lists. Nil for a row holding nothing.
    var lastWrittenAt: Double? {
        var latest: Double?
        func note(_ at: Double?) {
            guard let at else { return }
            latest = max(latest ?? at, at)
        }
        placements.values.forEach { note($0.at) }
        regions.values.forEach { note($0.at) }
        edges.values.forEach { note($0.at) }
        removed.values.forEach { note($0) }
        note(name?.at)
        note(trash?.at)
        note(notebook?.at)
        note(created)
        return latest
    }

    /// The earliest time anything on the canvas was written, for a canvas
    /// with no `created`.
    var firstWrittenAt: Double? {
        let stamps = placements.values.map(\.at) + regions.values.map(\.at) + edges.values.map(\.at)
            + removed.values + [name?.at, trash?.at, notebook?.at].compactMap { $0 }
        return stamps.min()
    }

    // MARK: Edits

    /// Puts a card at a spot. A card already placed keeps its size, fold,
    /// colour, page, words and marks: moving it is not restyling it.
    mutating func place(_ ref: String, x: Double, y: Double, at: Double) {
        var placement = placements[ref] ?? Placement(x: x, y: y, at: at)
        placement.x = x
        placement.y = y
        placement.at = at
        placements[ref] = placement
        removed.removeValue(forKey: "p:" + ref)
    }

    /// Writes a whole placement (its spot and its style), as Undo does.
    mutating func setPlacement(_ ref: String, _ placement: Placement) {
        placements[ref] = placement
        removed.removeValue(forKey: "p:" + ref)
    }

    mutating func unplace(_ ref: String, at: Double) {
        guard placements.removeValue(forKey: ref) != nil else { return }
        removed["p:" + ref] = at
        // An arrow is drawn between two placed cards; one whose end left the
        // map goes with it.
        for (id, edge) in edges where edge.from == ref || edge.to == ref {
            removeEdge(id, at: at)
        }
    }

    mutating func setRegion(_ id: String, _ region: Region) {
        regions[id] = region
        removed.removeValue(forKey: "r:" + id)
    }

    /// Removes a region. An arrow that ends at the region goes with it (an
    /// arrow to a region survives its cards leaving, not the region).
    mutating func removeRegion(_ id: String, at: Double) {
        guard regions.removeValue(forKey: id) != nil else { return }
        removed["r:" + id] = at
        for edgeID in edgesTouching(region: id) { removeEdge(edgeID, at: at) }
    }

    mutating func setEdge(_ id: String, _ edge: Edge) {
        edges[id] = edge
        removed.removeValue(forKey: "e:" + id)
    }

    mutating func removeEdge(_ id: String, at: Double) {
        guard edges.removeValue(forKey: id) != nil else { return }
        removed["e:" + id] = at
    }

    // MARK: Arrows to regions and mind-map branches

    /// The arrows that end at region `id` (`region:<id>`), by edge id.
    func edgesTouching(region id: String) -> [String] {
        let ref = KnowledgeMap.regionRef(id)
        return edges.filter { $0.value.from == ref || $0.value.to == ref }.keys.sorted()
    }

    /// The card a tree edge leads to `ref` from: the parent of a branch in a
    /// mind map. Nil for a root, or a card no branch reaches. A card with two
    /// parents (two Macs drew one each) has the one drawn first.
    func treeParent(of ref: String) -> String? {
        edges
            .filter { $0.value.isTree && $0.value.to == ref && KnowledgeMap.regionID(fromRef: $0.value.from) == nil }
            .min { ($0.value.at, $0.key) < ($1.value.at, $1.key) }?
            .value.from
    }

    /// The cards a card's tree edges lead to, top to bottom as they sit now,
    /// a card not placed yet after them in the order its branch was drawn.
    func treeChildren(of ref: String) -> [String] {
        let branches = edges
            .filter { $0.value.isTree && $0.value.from == ref && KnowledgeMap.regionID(fromRef: $0.value.to) == nil }
        func key(_ pair: (key: String, value: Edge)) -> (Double, Double, String) {
            (placements[pair.value.to]?.y ?? .infinity, pair.value.at, pair.key)
        }
        return branches.sorted { key($0) < key($1) }.map(\.value.to)
    }

    // MARK: Regions inside regions

    /// The region `id` is drawn inside: the smallest other region whose
    /// rect holds its whole rect (half a point of slack), or nil for a region
    /// inside none. Nothing is stored for nesting; the rects say so, as the
    /// renderer reads them (docs/knowledge-map-design.md, "Regions inside
    /// regions"). Two regions of one rect hold neither.
    func parentRegionID(of id: String) -> String? {
        guard let region = regions[id] else { return nil }
        return regions
            .filter { key, other in key != id && Self.rect(region, isInside: other) }
            .min { $0.value.w * $0.value.h < $1.value.w * $1.value.h }?
            .key
    }

    /// The regions drawn directly inside `id`, left to right then top to
    /// bottom.
    func nestedRegionIDs(in id: String) -> [String] {
        regions.keys
            .filter { parentRegionID(of: $0) == id }
            .sorted { a, b in
                let ra = regions[a]!, rb = regions[b]!
                return abs(ra.y - rb.y) < KnowledgeMap.cardHeight ? ra.x < rb.x : ra.y < rb.y
            }
    }

    /// The regions around `id`, outermost first.
    func regionPath(of id: String) -> [String] {
        var out: [String] = []
        var current = parentRegionID(of: id)
        while let next = current, !out.contains(next) {
            out.insert(next, at: 0)
            current = parentRegionID(of: next)
        }
        return out
    }

    private static func rect(_ a: Region, isInside b: Region) -> Bool {
        let slack = 0.5
        return a.x >= b.x - slack && a.y >= b.y - slack
            && a.x + a.w <= b.x + b.w + slack && a.y + a.h <= b.y + b.h + slack
            && a.w * a.h < b.w * b.h
    }

    // MARK: Merge

    /// The two copies merged entry by entry. Commutative, so whichever Mac
    /// merges first, both end with the same row.
    func merged(with other: KnowledgeMapLayout) -> KnowledgeMapLayout {
        var result = KnowledgeMapLayout()
        result.version = max(version, other.version)
        for (key, at) in removed { result.removed[key] = max(at, other.removed[key] ?? at) }
        for (key, at) in other.removed where result.removed[key] == nil { result.removed[key] = at }

        result.name = Self.newer(name, other.name, at: \.at)
        result.trash = Self.newer(trash, other.trash, at: \.at)
        result.notebook = Self.newer(notebook, other.notebook, at: \.at)
        result.created = [created, other.created].compactMap { $0 }.min()

        result.placements = Self.mergeEntries(placements, other.placements, tombstonePrefix: "p:", removed: result.removed, at: \.at)
        result.regions = Self.mergeEntries(regions, other.regions, tombstonePrefix: "r:", removed: result.removed, at: \.at)
        result.edges = Self.mergeEntries(edges, other.edges, tombstonePrefix: "e:", removed: result.removed, at: \.at)

        // A tombstone the surviving entry outlived is spent.
        for key in result.removed.keys {
            let id = String(key.dropFirst(2))
            switch key.prefix(2) {
            case "p:" where result.placements[id] != nil: result.removed.removeValue(forKey: key)
            case "r:" where result.regions[id] != nil: result.removed.removeValue(forKey: key)
            case "e:" where result.edges[id] != nil: result.removed.removeValue(forKey: key)
            default: break
            }
        }
        return result
    }

    private static func mergeEntries<Entry: Equatable>(
        _ lhs: [String: Entry],
        _ rhs: [String: Entry],
        tombstonePrefix: String,
        removed: [String: Double],
        at: KeyPath<Entry, Double>
    ) -> [String: Entry] {
        var result: [String: Entry] = [:]
        for key in Set(lhs.keys).union(rhs.keys) {
            let candidates = [lhs[key], rhs[key]].compactMap { $0 }
            // The newer write wins; on a tie the larger encoding does, so both
            // Macs pick the same one.
            guard let winner = candidates.max(by: { a, b in
                a[keyPath: at] != b[keyPath: at] ? a[keyPath: at] < b[keyPath: at] : String(describing: a) < String(describing: b)
            }) else { continue }
            if let tomb = removed[tombstonePrefix + key], tomb >= winner[keyPath: at] { continue }
            result[key] = winner
        }
        return result
    }

    /// The newer of two stamped marks; on a tie the larger encoding, so both
    /// Macs pick the same one.
    private static func newer<Mark>(_ lhs: Mark?, _ rhs: Mark?, at: KeyPath<Mark, Double>) -> Mark? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        if lhs[keyPath: at] != rhs[keyPath: at] { return lhs[keyPath: at] > rhs[keyPath: at] ? lhs : rhs }
        return String(describing: lhs) >= String(describing: rhs) ? lhs : rhs
    }

    /// Drops tombstones older than `tombstoneLifetime` before `now`.
    mutating func pruneTombstones(now: Double) {
        removed = removed.filter { now - $0.value < Self.tombstoneLifetime }
    }

    // MARK: The synced row

    /// The row's value: the layout as JSON text, sorted so equal layouts
    /// encode identically and a rewrite of the same layout is no write.
    var preferenceValue: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    init?(preferenceValue value: Any?) {
        let data: Data
        switch value {
        case let text as String: data = Data(text.utf8)
        case let raw as Data: data = raw
        default: return nil
        }
        guard let decoded = try? JSONDecoder().decode(KnowledgeMapLayout.self, from: data),
              decoded.version <= Self.currentVersion else { return nil }
        self = decoded
    }

    /// What `PreferenceStore.applyInbound` keeps for an inbound row: the two
    /// copies merged, and nil when the incoming row already holds everything
    /// (it is then taken as it arrives).
    static func mergedOnReceipt(incoming: Any, local: Any?) -> String? {
        guard let incomingLayout = KnowledgeMapLayout(preferenceValue: incoming),
              let localLayout = KnowledgeMapLayout(preferenceValue: local) else { return nil }
        let merged = localLayout.merged(with: incomingLayout)
        return merged == incomingLayout ? nil : merged.preferenceValue
    }
}

// MARK: - Lenses

/// A view ForeverLM lays the cards out in for a while, asked for in a chat:
/// the cards grouped under labels, placed on two axes, or set beside the
/// concepts of a topic in the order they connect ("zoom in on the PINK1–Parkin
/// axis and place the papers in context"). It changes nothing the learner
/// placed; Keep turns its spots into placements, and its groups or concepts
/// into regions.
struct KnowledgeMapLensRequest: Equatable, Sendable {
    enum Layout: String, Sendable {
        case groups
        case axes
        case concepts
    }

    /// One concept or step of a topic, in ForeverLM's words, with the cards
    /// that bear on it. A concept may have none: a step the library has no
    /// paper for still belongs in the picture.
    struct Concept: Equatable, Sendable {
        var label: String
        /// A sentence on what this concept is, drawn under its name.
        var note: String
        var items: [KnowledgeMap.ItemRef]
    }

    /// How one concept leads to another, by their labels: "recruits",
    /// "phosphorylates", "is needed for".
    struct ConceptLink: Equatable, Sendable {
        var from: String
        var to: String
        var label: String
    }

    struct Group: Equatable, Sendable {
        var label: String
        var items: [KnowledgeMap.ItemRef]
    }

    struct Axis: Equatable, Sendable {
        var label: String
        var low: String
        var high: String
    }

    struct Point: Equatable, Sendable {
        var item: KnowledgeMap.ItemRef
        /// 0 at the axis's low end, 1 at its high end.
        var x: Double
        var y: Double
    }

    var title: String
    var layout: Layout
    var groups: [Group] = []
    var xAxis: Axis?
    var yAxis: Axis?
    var points: [Point] = []
    var concepts: [Concept] = []
    var conceptLinks: [ConceptLink] = []
    /// Fade every card the lens does not name almost away (true), or only dim them.
    var hidesOthers = true

    var items: [KnowledgeMap.ItemRef] {
        switch layout {
        case .groups: return groups.flatMap(\.items)
        case .axes: return points.map(\.item)
        case .concepts: return concepts.flatMap(\.items)
        }
    }
}

/// A lens laid out in world space, ready for the renderer.
struct KnowledgeMapLens: Equatable, Sendable {
    struct Spot: Equatable, Sendable, Encodable {
        var x: Double
        var y: Double
    }

    struct Frame: Equatable, Sendable, Encodable {
        var label: String
        var x: Double
        var y: Double
        var w: Double
        var h: Double
        /// A concept's sentence, drawn under its name in ForeverLM's voice.
        var note: String = ""
    }

    /// An arrow between two of the lens's frames (a concepts lens), by their
    /// index in `frames`.
    struct Link: Equatable, Sendable, Encodable {
        var from: Int
        var to: Int
        var label: String
    }

    struct Axes: Equatable, Sendable, Encodable {
        struct End: Equatable, Sendable, Encodable {
            var label: String
            var low: String
            var high: String
        }
        var x: End?
        var y: End?
        var frame: Frame
    }

    var id = UUID()
    var title: String
    var positions: [String: Spot]
    var frames: [Frame]
    var axes: Axes?
    var links: [Link] = []
    var hidesOthers: Bool

    static func == (lhs: KnowledgeMapLens, rhs: KnowledgeMapLens) -> Bool { lhs.id == rhs.id }

    /// Spacing between cards in a lens.
    static let cellWidth = KnowledgeMap.cardWidth + 26
    static let cellHeight = KnowledgeMap.cardHeight + 26
    /// Room above a group's cards for its name.
    static let frameHeader: Double = 120
    static let framePadding: Double = 30
    static let frameGap: Double = 180
    /// The axes' plotting area.
    static let axesSize = (w: 3200.0, h: 2000.0)
    /// Room above a concept's cards for its name and its sentence.
    static let conceptHeader: Double = 190
    /// Between two columns of concepts, room for the arrow and its label.
    static let conceptColumnGap: Double = 420

    /// Lays `request` out centred on `center`, keeping only the items `known`
    /// accepts (a ref the library no longer holds is dropped) and each item
    /// once (its first group, its first point). `height` is each card's
    /// height on the plane (a clip is as tall as its picture), so a row of
    /// cards is as tall as its tallest and no card covers the one below.
    static func laidOut(
        _ request: KnowledgeMapLensRequest,
        center: (x: Double, y: Double),
        height: (KnowledgeMap.ItemRef) -> Double,
        known: (KnowledgeMap.ItemRef) -> Bool
    ) -> KnowledgeMapLens {
        switch request.layout {
        case .groups: return groupsLayout(request, center: center, height: height, known: known)
        case .axes: return axesLayout(request, center: center, height: height, known: known)
        case .concepts: return conceptsLayout(request, center: center, height: height, known: known)
        }
    }

    /// The concepts in columns by how far down the chain each one is (a
    /// concept nothing leads to on the left, what it leads to to its right),
    /// stacked in the order given within a column; each concept a block of
    /// its cards at most three wide, under its name and sentence. A link that
    /// closes a loop is still drawn but does not move a concept right.
    private static func conceptsLayout(
        _ request: KnowledgeMapLensRequest,
        center: (x: Double, y: Double),
        height: (KnowledgeMap.ItemRef) -> Double,
        known: (KnowledgeMap.ItemRef) -> Bool
    ) -> KnowledgeMapLens {
        var seenLabels: Set<String> = []
        var seenItems: Set<KnowledgeMap.ItemRef> = []
        let concepts: [(label: String, note: String, items: [KnowledgeMap.ItemRef])] = request.concepts.compactMap { concept in
            let label = concept.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, seenLabels.insert(label.lowercased()).inserted else { return nil }
            let items = concept.items.filter { known($0) && seenItems.insert($0).inserted }
            return (label, concept.note.trimmingCharacters(in: .whitespacesAndNewlines), items)
        }
        let index = Dictionary(concepts.enumerated().map { ($1.label.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var links: [Link] = []
        for link in request.conceptLinks {
            guard let from = index[link.from.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()],
                  let to = index[link.to.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()],
                  from != to,
                  !links.contains(where: { $0.from == from && $0.to == to }) else { continue }
            links.append(Link(from: from, to: to, label: link.label.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        let columns = conceptColumns(count: concepts.count, links: links.map { ($0.from, $0.to) })

        let sizes = concepts.map { concept -> (cols: Int, w: Double, h: Double, rowTops: [Double]) in
            let n = concept.items.count
            let cols = max(1, min(3, Int(Double(n).squareRoot().rounded(.up))))
            let rows = KnowledgeMapArranging.rowTops(heights: concept.items.map(height), cols: cols, gap: cellHeight - KnowledgeMap.cardHeight)
            let w = Double(cols) * cellWidth - 26 + framePadding * 2
            let h = conceptHeader + (n == 0 ? 0 : rows.height + framePadding)
            return (cols, w, h, rows.tops)
        }
        let columnCount = (columns.max() ?? -1) + 1
        var columnWidths = Array(repeating: 0.0, count: columnCount)
        var columnHeights = Array(repeating: 0.0, count: columnCount)
        for (i, column) in columns.enumerated() {
            columnWidths[column] = max(columnWidths[column], sizes[i].w)
            columnHeights[column] += (columnHeights[column] > 0 ? frameGap : 0) + sizes[i].h
        }
        let totalW = columnWidths.reduce(0, +) + conceptColumnGap * Double(max(0, columnCount - 1))
        var columnX: [Double] = []
        var x = center.x - totalW / 2
        for width in columnWidths {
            columnX.append(x)
            x += width + conceptColumnGap
        }
        var nextY = columnHeights.map { center.y - $0 / 2 }
        var frames: [Frame] = []
        var positions: [String: Spot] = [:]
        for (i, concept) in concepts.enumerated() {
            let column = columns[i], size = sizes[i]
            let fx = columnX[column] + (columnWidths[column] - size.w) / 2
            let fy = nextY[column]
            nextY[column] += size.h + frameGap
            frames.append(Frame(label: concept.label, x: fx.rounded(), y: fy.rounded(), w: size.w, h: size.h, note: concept.note))
            for (k, item) in concept.items.enumerated() {
                positions[item.description] = Spot(
                    x: (fx + framePadding + Double(k % size.cols) * cellWidth).rounded(),
                    y: (fy + conceptHeader + size.rowTops[k / size.cols]).rounded()
                )
            }
        }
        return KnowledgeMapLens(title: request.title, positions: positions, frames: frames, axes: nil, links: links, hidesOthers: request.hidesOthers)
    }

    /// Each concept's column: the longest chain of links leading to it,
    /// following links in the order given and skipping one that would close a
    /// loop.
    static func conceptColumns(count: Int, links: [(from: Int, to: Int)]) -> [Int] {
        var outgoing = Array(repeating: [Int](), count: count)
        for link in links where link.from < count && link.to < count { outgoing[link.from].append(link.to) }
        // A depth-first walk in the given order: an edge back to a concept
        // still on the walk closes a loop and is left out of the ordering.
        var state = Array(repeating: 0, count: count) // 0 new, 1 on the walk, 2 done
        var order: [Int] = []
        var kept = Array(repeating: [Int](), count: count)
        func visit(_ node: Int) {
            state[node] = 1
            for next in outgoing[node] where state[next] != 1 {
                kept[node].append(next)
                if state[next] == 0 { visit(next) }
            }
            state[node] = 2
            order.append(node)
        }
        for node in 0..<count where state[node] == 0 { visit(node) }
        var column = Array(repeating: 0, count: count)
        for node in order.reversed() {
            for next in kept[node] { column[next] = max(column[next], column[node] + 1) }
        }
        return column
    }

    private static func groupsLayout(
        _ request: KnowledgeMapLensRequest,
        center: (x: Double, y: Double),
        height: (KnowledgeMap.ItemRef) -> Double,
        known: (KnowledgeMap.ItemRef) -> Bool
    ) -> KnowledgeMapLens {
        var seen: Set<KnowledgeMap.ItemRef> = []
        let groups: [(label: String, items: [KnowledgeMap.ItemRef])] = request.groups.compactMap { group in
            let items = group.items.filter { known($0) && seen.insert($0).inserted }
            return items.isEmpty ? nil : (group.label, items)
        }
        // Each group a block of cards about 3:2 wide; blocks in rows of up to
        // four.
        let sizes = groups.map { group -> (cols: Int, w: Double, h: Double, rowTops: [Double]) in
            let cols = max(1, Int((Double(group.items.count) * 1.5).squareRoot().rounded(.up)))
            let rows = KnowledgeMapArranging.rowTops(heights: group.items.map(height), cols: cols, gap: cellHeight - KnowledgeMap.cardHeight)
            let w = Double(cols) * cellWidth - 26 + framePadding * 2
            let h = frameHeader + rows.height + framePadding
            return (cols, w, h, rows.tops)
        }
        let perRow = min(4, max(1, Int(Double(groups.count).squareRoot().rounded(.up))))
        var frames: [Frame] = []
        var positions: [String: Spot] = [:]
        var x = 0.0, y = 0.0, rowHeight = 0.0
        var origins: [(Double, Double)] = []
        for (index, size) in sizes.enumerated() {
            if index > 0, index % perRow == 0 {
                x = 0
                y += rowHeight + frameGap
                rowHeight = 0
            }
            origins.append((x, y))
            x += size.w + frameGap
            rowHeight = max(rowHeight, size.h)
        }
        let totalW = zip(origins, sizes).map { $0.0 + $1.w }.max() ?? 0
        let totalH = zip(origins, sizes).map { $0.1 + $1.h }.max() ?? 0
        let ox = center.x - totalW / 2, oy = center.y - totalH / 2
        for (index, group) in groups.enumerated() {
            let size = sizes[index]
            let fx = ox + origins[index].0, fy = oy + origins[index].1
            frames.append(Frame(label: group.label, x: fx, y: fy, w: size.w, h: size.h))
            for (i, item) in group.items.enumerated() {
                positions[item.description] = Spot(
                    x: (fx + framePadding + Double(i % size.cols) * cellWidth).rounded(),
                    y: (fy + frameHeader + size.rowTops[i / size.cols]).rounded()
                )
            }
        }
        return KnowledgeMapLens(title: request.title, positions: positions, frames: frames, axes: nil, hidesOthers: request.hidesOthers)
    }

    private static func axesLayout(
        _ request: KnowledgeMapLensRequest,
        center: (x: Double, y: Double),
        height: (KnowledgeMap.ItemRef) -> Double,
        known: (KnowledgeMap.ItemRef) -> Bool
    ) -> KnowledgeMapLens {
        let frame = Frame(
            label: "",
            x: center.x - axesSize.w / 2,
            y: center.y - axesSize.h / 2,
            w: axesSize.w,
            h: axesSize.h
        )
        var seen: Set<KnowledgeMap.ItemRef> = []
        var positions: [String: Spot] = [:]
        var taken: [KnowledgeMapArranging.Rect] = []
        let spanX = frame.w - KnowledgeMap.cardWidth
        let spanY = frame.h - KnowledgeMap.cardHeight
        for point in request.points where known(point.item) && seen.insert(point.item).inserted {
            let px = min(max(point.x, 0), 1), py = min(max(point.y, 0), 1)
            var spot = Spot(x: (frame.x + px * spanX).rounded(), y: (frame.y + (1 - py) * spanY).rounded())
            // Two cards on one spot would hide each other: step the later one
            // down until it overlaps nothing, a few rows at most.
            let tall = height(point.item)
            func card() -> KnowledgeMapArranging.Rect { .init(x: spot.x, y: spot.y, w: KnowledgeMap.cardWidth, h: tall) }
            var tries = 0
            while tries < 12, taken.contains(where: { $0.intersects(card()) }) {
                spot.y += cellHeight
                tries += 1
            }
            taken.append(card())
            positions[point.item.description] = spot
        }
        let axes = Axes(
            x: request.xAxis.map { Axes.End(label: $0.label, low: $0.low, high: $0.high) },
            y: request.yAxis.map { Axes.End(label: $0.label, low: $0.low, high: $0.high) },
            frame: frame
        )
        return KnowledgeMapLens(title: request.title, positions: positions, frames: [], axes: axes, hidesOthers: request.hidesOthers)
    }
}

extension KnowledgeMapLens: Encodable {
    private enum CodingKeys: String, CodingKey {
        case title, positions, frames, axes, links, hideOthers
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(positions, forKey: .positions)
        try container.encode(frames, forKey: .frames)
        try container.encodeIfPresent(axes, forKey: .axes)
        try container.encode(links, forKey: .links)
        try container.encode(hidesOthers, forKey: .hideOthers)
    }
}

// MARK: - What the renderer draws

/// One card as the renderer receives it: its faces at each zoom level.
struct KnowledgeMapNode: Encodable, Equatable, Sendable {
    /// `source:<id>`, `doc:<id>`, `idea:<id>`, `clip:<id>`, `page:<id>:<n>`,
    /// `canvas:<id>`, `chat:<id>` or `picture:<id>`.
    var ref: String
    var kind: String
    /// What tints its dot: a source's type (`paper`, `podcast`…), a made
    /// thing's kind (`doc`, `site`, `animation`, `audio`, `reading`), `idea`
    /// for a note, `canvas`, `chat` or `picture` for those cards.
    var type: String
    var title: String
    /// Authors · year · venue, or a note's first line of text.
    var sub: String
    /// The card's detail face: its notebooks, its chats, the learner's first highlight.
    var detail: [String]
    /// The notebook cluster it waits in on the shore until it is placed.
    var shore: String
    /// The series it belongs to (a book's chapters, a show's episodes, a
    /// course's lectures, a playlist's videos), so the Canvas can stack it
    /// with the rest of the series in a region.
    var group: String? = nil
    var groupTitle: String? = nil
    /// The card's height in world units when it is not the usual
    /// `cardHeight`: a clip is as tall as its picture.
    var h: Double? = nil
    /// The words of a passage card (`ReaderClip.isPassage`); nil for every
    /// other card.
    var quote: String? = nil
    /// A figure clip's printed caption, shown in its foot; nil for a clip the
    /// learner cut that matches no figure, a passage or a page.
    var caption: String? = nil
    /// The paper a clip or page card was cut from (`source:<id>`) and its
    /// byline, so a region holding only that paper's cards reads as the
    /// paper: its picture, authors, venue and year, as the Library shows it.
    var src: String? = nil
    var byline: String? = nil
    /// How many pages the source's PDF has and its first page's width over
    /// its height, once this Mac has read it (`KnowledgeMapModel.pageFaces`):
    /// what a page face needs to be drawn. Nil until then.
    var pages: Int? = nil
    var aspect: Double? = nil
    /// True for a source the learner has read (`StudioArticle.isRead`): the
    /// page draws a small tick on its corner. Nil for any other.
    var read: Bool? = nil
}

/// One page of a PDF source that is a card on a canvas: its ref and the
/// page's width over its height when known.
struct KnowledgeMapPageCard: Equatable, Sendable {
    var ref: String
    var aspect: Double?
}

/// One image of the Images library as the Canvas reads it: its id, its name
/// and its width over its height when known (`picture:<imageID>`).
struct KnowledgeMapPictureCard: Equatable, Sendable {
    var imageID: String
    var title: String
    var aspect: Double?
    /// The file of its latest version, where its picture is read from.
    var path: String?

    var ref: String { KnowledgeMap.ItemRef(kind: .picture, id: imageID).description }
}

/// A computed relation the renderer draws from a focused card: two items
/// discussed in one chat, cited by one Doc, or linked by an Idea.
struct KnowledgeMapLink: Encodable, Equatable, Sendable {
    var a: String
    var b: String
    var kind: String
}

/// One edit of the learner's to the Canvas, as the row was before and after it,
/// for Undo and Redo (`KnowledgeMapModel.undo()`). Undoing writes back only
/// the entries the edit changed, so what another Mac changed meanwhile, in any
/// other entry, stays.
struct KnowledgeMapEdit: Equatable, Sendable {
    var before: KnowledgeMapLayout
    var after: KnowledgeMapLayout
    var at: Date
    /// An edit that stands alone: a Restore of a version is never folded into
    /// the burst of edits around it, nor are later ones folded into it.
    var sealed = false

    /// Whether the edit changed any card, region or arrow.
    var changes: Bool {
        before.placements != after.placements || before.regions != after.regions || before.edges != after.edges
    }

    /// Writes `target`'s value of every entry this edit changed into `layout`,
    /// at time `at`: placements first, so an arrow coming back has both ends.
    func restore(_ target: KnowledgeMapLayout, into layout: inout KnowledgeMapLayout, at: Double) {
        for key in Self.changedKeys(before.placements, after.placements) {
            // The whole placement comes back: its spot and its size, fold, colour, page, words and marks.
            if var placement = target.placements[key] { placement.at = at; layout.setPlacement(key, placement) } else { layout.unplace(key, at: at) }
        }
        for key in Self.changedKeys(before.regions, after.regions) {
            if var region = target.regions[key] { region.at = at; layout.setRegion(key, region) } else { layout.removeRegion(key, at: at) }
        }
        for key in Self.changedKeys(before.edges, after.edges) {
            if var edge = target.edges[key] { edge.at = at; layout.setEdge(key, edge) } else { layout.removeEdge(key, at: at) }
        }
    }

    private static func changedKeys<Entry: Equatable>(_ a: [String: Entry], _ b: [String: Entry]) -> [String] {
        Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }.sorted()
    }
}

/// A notebook as the renderer receives it, for the regions linked to it:
/// its name, its own short description, and the cards it holds.
struct KnowledgeMapNotebook: Encodable, Equatable, Sendable {
    var id: String
    var title: String
    var summary: String
    /// Its sources and the Docs it made, as card refs, in the notebook's order.
    var refs: [String]
}

struct KnowledgeMapContent: Encodable, Equatable, Sendable {
    var nodes: [KnowledgeMapNode]
    var links: [KnowledgeMapLink]
    var notebooks: [KnowledgeMapNotebook] = []
}

// MARK: - Extending to another display

/// The geometry of the Map extended to a second display
/// (docs/knowledge-map-design.md, "Extending to another display"): a second
/// Map window on the other screen shows the part of the plane next to the
/// first window's, on the side the displays are arranged, so the two read as
/// one wide canvas.
///
/// Frames are in AppKit's global screen space: points, y up. A point is one
/// CSS pixel in the renderer at any backing scale, so a camera carries from a
/// Retina display to a non-Retina one unchanged; each page draws at its own
/// display's pixel density.
enum KnowledgeMapDisplays {
    /// Where the other display sits, seen from the first window's display.
    enum Side: String, Sendable, CaseIterable {
        case left, right, above, below

        var opposite: Side {
            switch self {
            case .left: return .right
            case .right: return .left
            case .above: return .below
            case .below: return .above
            }
        }

        /// The edge of a view facing this side, as the renderer names it
        /// (its y runs down, so above is its top).
        var rendererEdge: String {
            switch self {
            case .left: return "left"
            case .right: return "right"
            case .above: return "top"
            case .below: return "bottom"
            }
        }
    }

    /// The renderer's camera: a point at world (x, y) draws at
    /// (x·scale + ox, y·scale + oy) in its view, in points from the top left.
    struct Camera: Equatable, Sendable {
        var scale: Double
        var ox: Double
        var oy: Double
    }

    /// The display the Map extends to: of the screens other than `primary`,
    /// the one whose centre is nearest. Nil with one display.
    static func otherScreen(from primary: CGRect, among screens: [CGRect]) -> CGRect? {
        func distance(_ frame: CGRect) -> Double {
            hypot(Double(frame.midX - primary.midX), Double(frame.midY - primary.midY))
        }
        return screens.filter { $0 != primary }.min { distance($0) < distance($1) }
    }

    /// Which side of `primary` the `other` display is on. A display that is
    /// beside it on one axis only is on that side; one placed diagonally, or
    /// overlapping, is on the axis its centre is further along.
    static func side(of other: CGRect, from primary: CGRect) -> Side {
        let slack: CGFloat = 1
        let right = other.minX >= primary.maxX - slack
        let left = other.maxX <= primary.minX + slack
        let above = other.minY >= primary.maxY - slack
        let below = other.maxY <= primary.minY + slack
        let horizontal = right || left
        let vertical = above || below
        if horizontal && !vertical { return right ? .right : .left }
        if vertical && !horizontal { return above ? .above : .below }
        let dx = other.midX - primary.midX, dy = other.midY - primary.midY
        if abs(dx) >= abs(dy) { return dx >= 0 ? .right : .left }
        return dy >= 0 ? .above : .below
    }

    /// What the second window's camera adds to the first's offset. Along the
    /// side, the second view's edge continues exactly where the first view's
    /// edge ends: the first viewport's width or height in plane units, so no
    /// part of the plane is skipped for the gap between the windows. Across
    /// it, both views keep their places on the desk, so a line drawn across
    /// the plane runs straight over the bezel.
    static func offset(side: Side, primary: CGRect, secondary: CGRect) -> (dx: Double, dy: Double) {
        // Top edges, in a y-down view: a higher top shows the plane lower.
        let acrossY = Double(secondary.maxY - primary.maxY)
        let acrossX = Double(primary.minX - secondary.minX)
        switch side {
        case .right: return (-Double(primary.width), acrossY)
        case .left: return (Double(secondary.width), acrossY)
        case .below: return (acrossX, -Double(primary.height))
        case .above: return (acrossX, Double(secondary.height))
        }
    }

    /// The second window's camera, following the first: the same zoom, the
    /// origin moved by `offset`.
    static func secondaryCamera(following camera: Camera, side: Side, primary: CGRect, secondary: CGRect) -> Camera {
        let d = offset(side: side, primary: primary, secondary: secondary)
        return Camera(scale: camera.scale, ox: camera.ox + d.dx, oy: camera.oy + d.dy)
    }

    /// The first window's camera, following the second: the inverse.
    static func primaryCamera(following camera: Camera, side: Side, primary: CGRect, secondary: CGRect) -> Camera {
        let d = offset(side: side, primary: primary, secondary: secondary)
        return Camera(scale: camera.scale, ox: camera.ox - d.dx, oy: camera.oy - d.dy)
    }

    /// The desk between the two views along the side, never negative: how
    /// far a dragged card's pointer travels outside both before it reaches
    /// the other view. The renderer skips it, so a card carried across lands
    /// under the pointer.
    static func gap(side: Side, primary: CGRect, secondary: CGRect) -> Double {
        switch side {
        case .right: return max(0, Double(secondary.minX - primary.maxX))
        case .left: return max(0, Double(primary.minX - secondary.maxX))
        case .above: return max(0, Double(secondary.minY - primary.maxY))
        case .below: return max(0, Double(primary.minY - secondary.maxY))
        }
    }
}

/// Where cards and regions go when the learner asks for them to be set down
/// somewhere without carrying them there (over MCP or the in-app chat): on
/// the renderer's grid (cards 30 apart, inset 50 by 60 in a region, as a drop
/// lays them out), never on top of a card or region already there.
enum KnowledgeMapArranging {
    struct Spot: Equatable, Sendable {
        var x: Double
        var y: Double
    }

    struct Rect: Equatable, Sendable {
        var x: Double
        var y: Double
        var w: Double
        var h: Double

        func intersects(_ other: Rect) -> Bool {
            x < other.x + other.w && other.x < x + w && y < other.y + other.h && other.y < y + h
        }
    }

    static let gap: Double = 30
    static let insetX: Double = 50
    static let insetY: Double = 60
    /// A region made with nothing in it yet: three cards across, two down.
    static let emptyRegionSize = (w: 900.0, h: 400.0)

    /// A free cell of a region's grid for each card of `heights` (a card's
    /// own height: a clip is as tall as its picture), row after row from its
    /// top left: the first cell where that card covers nothing in `taken`
    /// (each placed card with its own height) nor a card set down before
    /// it. Returns those cells and the region's height once it holds them
    /// (never less than it was).
    ///
    /// `widths` is each card's own width when any is not the usual 240; a
    /// wider card takes the cells it covers.
    static func spots(heights: [Double], widths: [Double]? = nil, in region: Rect, taken: [Rect]) -> (spots: [Spot], height: Double) {
        let stepX = KnowledgeMap.cardWidth + gap, stepY = KnowledgeMap.cardHeight + gap
        let cols = max(1, Int((region.w - insetX * 2 + gap) / stepX))
        var covered = taken
        var out: [Spot] = []
        for (index, height) in heights.enumerated() {
            var cell = 0
            while true {
                let spot = Spot(x: region.x + insetX + Double(cell % cols) * stepX, y: region.y + insetY + Double(cell / cols) * stepY)
                cell += 1
                let card = Rect(x: spot.x, y: spot.y, w: widths?[index] ?? KnowledgeMap.cardWidth, h: height)
                if covered.contains(where: { $0.intersects(card) }) { continue }
                out.append(spot)
                covered.append(card)
                break
            }
        }
        guard let bottom = zip(out, heights).map({ $0.y + $1 }).max() else { return (out, region.h) }
        return (out, max(region.h, bottom + insetY - 10 - region.y))
    }

    /// The cards of `heights` as one block, as a drop sets them down (about
    /// half again as wide as tall), with its top-left card at `origin`, each
    /// row as tall as its tallest card, and the region that frames it.
    ///
    /// `widths` is each card's own width when any is not the usual 240; a
    /// column is as wide as its widest card.
    static func block(heights: [Double], widths: [Double]? = nil, origin: Spot) -> (spots: [Spot], frame: Rect) {
        let count = heights.count
        let cols = max(1, Int((Double(max(count, 1)) * 1.5).squareRoot().rounded(.up)))
        let rows = rowTops(heights: heights, cols: cols, gap: gap)
        let lefts = columnLefts(widths: widths ?? Array(repeating: KnowledgeMap.cardWidth, count: count), cols: cols)
        let spots = heights.indices.map { i in
            Spot(x: origin.x + lefts.lefts[i % cols], y: origin.y + rows.tops[i / cols])
        }
        let w = count == 0 ? KnowledgeMap.cardWidth : lefts.width
        let h = count == 0 ? KnowledgeMap.cardHeight : rows.height
        return (spots, Rect(x: origin.x - insetX, y: origin.y - insetY, w: w + insetX * 2, h: h + insetY + insetX))
    }

    /// The cards of `heights` as one row, left to right in the order given,
    /// tops level at `origin`, and the region that frames it: how a PDF's
    /// pages are laid out, page after page, as a paper reads. A row is as
    /// wide as it needs to be; the plane has the room.
    ///
    /// `widths` is each card's own width when any is not the usual 240.
    static func row(heights: [Double], widths: [Double]? = nil, origin: Spot) -> (spots: [Spot], frame: Rect) {
        let count = heights.count
        let lefts = columnLefts(widths: widths ?? Array(repeating: KnowledgeMap.cardWidth, count: count), cols: max(count, 1))
        let spots = (0..<count).map { Spot(x: origin.x + lefts.lefts[$0], y: origin.y) }
        let w = count == 0 ? KnowledgeMap.cardWidth : lefts.width
        let h = heights.max() ?? KnowledgeMap.cardHeight
        return (spots, Rect(x: origin.x - insetX, y: origin.y - insetY, w: w + insetX * 2, h: h + insetY + insetX))
    }

    /// Where each of `cols` columns starts, from 0, when a column is as wide
    /// as the widest of `widths` in it (cards going across, `cols` to a row)
    /// and columns are `gap` apart, and the width of all of them.
    static func columnLefts(widths: [Double], cols: Int) -> (lefts: [Double], width: Double) {
        let cols = max(1, cols)
        var columnWidths = Array(repeating: 0.0, count: cols)
        for (i, width) in widths.enumerated() { columnWidths[i % cols] = max(columnWidths[i % cols], width) }
        let used = min(cols, max(widths.count, 1))
        var lefts: [Double] = []
        var x = 0.0
        for c in 0..<cols {
            lefts.append(x)
            x += columnWidths[c] + gap
        }
        let width = (0..<used).reduce(0.0) { $0 + columnWidths[$1] } + Double(used - 1) * gap
        return (lefts, width)
    }

    /// Where each row of a block `cols` cards wide starts, from 0, when every
    /// row is as tall as its tallest card and rows are `gap` apart, and the
    /// height of all of them.
    static func rowTops(heights: [Double], cols: Int, gap: Double) -> (tops: [Double], height: Double) {
        let cols = max(1, cols)
        var tops: [Double] = []
        var y = 0.0
        var start = 0
        while start < heights.count {
            tops.append(y)
            y += (heights[start..<min(heights.count, start + cols)].max() ?? KnowledgeMap.cardHeight) + gap
            start += cols
        }
        return (tops, tops.isEmpty ? 0 : y - gap)
    }

    /// The top left of a free stretch `size` big for a long row of cards: the
    /// row's left edge sits at `left` (so its first card is in view), and
    /// the row goes down, a row's height and a margin at a time, until it
    /// overlaps nothing in `occupied`.
    static func freeRowOrigin(size: (w: Double, h: Double), left: Double, top: Double, occupied: [Rect]) -> Spot {
        let margin: Double = 120
        for i in 0..<200 {
            let candidate = Spot(x: left, y: top + Double(i) * (size.h + margin))
            let rect = Rect(x: candidate.x - margin / 2, y: candidate.y - margin / 2, w: size.w + margin, h: size.h + margin)
            if !occupied.contains(where: { $0.intersects(rect) }) { return candidate }
        }
        return Spot(x: left, y: (occupied.map { $0.y + $0.h }.max() ?? top) + margin)
    }

    /// The top left of a free stretch of the plane `size` big, as near
    /// `center` as it can be: the spot centred there, else the first one
    /// to its right or below (in steps of the size) that overlaps nothing
    /// in `occupied`, else below everything.
    static func freeOrigin(size: (w: Double, h: Double), near center: Spot, occupied: [Rect]) -> Spot {
        let margin: Double = 120
        let start = Spot(x: (center.x - size.w / 2).rounded(), y: (center.y - size.h / 2).rounded())
        for i in 0..<64 {
            let candidate = Spot(x: start.x + Double(i % 8) * (size.w + margin), y: start.y + Double(i / 8) * (size.h + margin))
            let rect = Rect(x: candidate.x - margin / 2, y: candidate.y - margin / 2, w: size.w + margin, h: size.h + margin)
            if !occupied.contains(where: { $0.intersects(rect) }) { return candidate }
        }
        let bottom = occupied.map { $0.y + $0.h }.max() ?? start.y
        return Spot(x: start.x, y: bottom + margin)
    }
}
