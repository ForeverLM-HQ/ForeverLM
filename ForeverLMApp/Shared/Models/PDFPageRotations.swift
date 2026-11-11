import Foundation

// MARK: - Turned pages of a PDF source

/// The pages of one PDF source the learner turned, and by how much.
///
/// A library PDF is shared content in iCloud and is never rewritten for a
/// reading preference, so a turn is the member's own state, kept beside the
/// source's id and applied to the in-memory document when it opens
/// (`PDFPage.rotation`). One synced preference row per source
/// (`SyncedPreferenceKeys.syncedPrefixes`, as `PagePins` keeps pins): two
/// devices turning pages of two papers keep both, the row follows the account,
/// and a team's copy of the source never carries it. No schema change.
///
/// `reader.pdfRotations.<sourceID>` holds `{"<page>": <degrees>}` as JSON text.
/// A page is zero-based in the source's own numbering, so a chapter of a book
/// counts from its own first page, as every highlight does. Degrees are
/// clockwise turns *added to* the page's own rotation in the file (a scan whose
/// pages are stored sideways keeps its correction), in 90, 180 and 270; a page
/// turned all the way round is no entry. A page before a book's first chapter,
/// or between chapters, is numbered from the chapter that opens before it, and
/// from the first chapter when none does, so it can be negative.
/// Foundation-only, so the phone and the web can read the same row.
struct PDFPageRotations: Equatable, Sendable {
    static let preferenceKeyPrefix = Prefs.Families.pdfRotations.prefix
    /// Clockwise degrees (90, 180 or 270) by page of the source.
    private(set) var turns: [Int: Int]

    init(turns: [Int: Int] = [:]) {
        var kept: [Int: Int] = [:]
        for (page, degrees) in turns {
            let normalized = Self.normalized(degrees)
            if normalized != 0 { kept[page] = normalized }
        }
        self.turns = kept
    }

    var isEmpty: Bool { turns.isEmpty }

    /// The turn of a page, 0 when it has none.
    func degrees(of page: Int) -> Int {
        turns[page] ?? 0
    }

    /// The same turns with `page` turned a further `degrees` clockwise (a
    /// negative number turns it back); a page that comes full circle is dropped.
    func turned(_ page: Int, by turn: Int) -> PDFPageRotations {
        var next = turns
        next[page] = Self.normalized(degrees(of: page) + turn)
        return PDFPageRotations(turns: next)
    }

    /// 0, 90, 180 or 270 for any multiple of 90, in either direction; anything
    /// that is not a quarter turn is no turn at all.
    static func normalized(_ degrees: Int) -> Int {
        guard degrees % 90 == 0 else { return 0 }
        return ((degrees % 360) + 360) % 360
    }

    // MARK: The preference row

    static func key(sourceID: String) -> String {
        preferenceKeyPrefix + sourceID
    }

    static func sourceID(fromKey key: String) -> String? {
        guard key.hasPrefix(preferenceKeyPrefix) else { return nil }
        let id = String(key.dropFirst(preferenceKeyPrefix.count))
        return id.isEmpty ? nil : id
    }

    /// The row's text for a source's turns, with sorted keys so a re-save is no
    /// change and two devices never trade key orders; nil when there are none,
    /// which is the row's absence.
    var storedValue: String? {
        guard !turns.isEmpty else { return nil }
        var object: [String: Int] = [:]
        for (page, degrees) in turns { object[String(page)] = degrees }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The turns a row's value holds; an unreadable value is no turns, since a
    /// page left upright is the harmless way to be wrong.
    init(storedValue: Any?) {
        guard let text = storedValue as? String,
              let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            self.init()
            return
        }
        var turns: [Int: Int] = [:]
        for (key, value) in object {
            guard let page = Int(key), let degrees = (value as? NSNumber)?.intValue else { continue }
            turns[page] = degrees
        }
        self.init(turns: turns)
    }
}

/// Where a page of a document assembled from several sources is filed: the
/// source whose turns hold it, and its number in that source.
///
/// `starts` are the first pages of each source's run, in reading order. A page
/// belongs to the last run that has begun by then, and to the first run when
/// none has, so every page of the document has one home and a page's number
/// does not move when a later chapter does.
struct PDFPageRotationOwner: Equatable, Sendable {
    struct Run: Equatable, Sendable {
        let sourceID: String
        let firstPage: Int

        init(sourceID: String, firstPage: Int) {
            self.sourceID = sourceID
            self.firstPage = firstPage
        }
    }

    let runs: [Run]

    init(runs: [Run]) {
        self.runs = runs.sorted { $0.firstPage < $1.firstPage }
    }

    /// The source and page-in-source of a page of the document; nil only for a
    /// document with no runs.
    func home(ofPage page: Int) -> (sourceID: String, pageInSource: Int)? {
        guard let first = runs.first else { return nil }
        let run = runs.last { $0.firstPage <= page } ?? first
        return (run.sourceID, page - run.firstPage)
    }

    /// The page of the document a source's page is, the inverse of `home`.
    func page(ofSource sourceID: String, pageInSource: Int) -> Int? {
        runs.first { $0.sourceID == sourceID }.map { $0.firstPage + pageInSource }
    }
}

/// The two ways a quarter-turned page maps a point of the page as it is stored,
/// for the few things drawn over a page in the page's own coordinates.
///
/// PDFKit gives selections, annotations, text lookups and page bounds in the
/// page's stored orientation whatever its `rotation` (measured on macOS: the
/// bounds of "Hello" on a page are the same rect at 0, 90, 180 and 270), so
/// highlights, find and citations need no mapping and stay put when a page is
/// turned. A view laid over the *displayed* page does: a rect in stored
/// coordinates lands somewhere else once the page is on its side.
enum PDFPageTurn {
    /// A rect of a page stored `width` by `height` (origin at the box's
    /// corner), as a rect of the page displayed turned `degrees` clockwise: the
    /// displayed page is `height` by `width` for a quarter turn, y up.
    static func displayedRect(
        _ rect: (x: Double, y: Double, width: Double, height: Double),
        pageWidth width: Double,
        pageHeight height: Double,
        degrees: Int
    ) -> (x: Double, y: Double, width: Double, height: Double) {
        let x0 = rect.x, y0 = rect.y, x1 = rect.x + rect.width, y1 = rect.y + rect.height
        func map(_ x: Double, _ y: Double) -> (Double, Double) {
            switch PDFPageRotations.normalized(degrees) {
            case 90: return (y, width - x)
            case 180: return (width - x, height - y)
            case 270: return (height - y, x)
            default: return (x, y)
            }
        }
        let a = map(x0, y0), b = map(x1, y1)
        return (min(a.0, b.0), min(a.1, b.1), abs(a.0 - b.0), abs(a.1 - b.1))
    }

    /// The size of a page displayed `degrees` clockwise from stored `width` by
    /// `height`.
    static func displayedSize(
        pageWidth width: Double,
        pageHeight height: Double,
        degrees: Int
    ) -> (width: Double, height: Double) {
        let turn = PDFPageRotations.normalized(degrees)
        return turn == 90 || turn == 270 ? (height, width) : (width, height)
    }
}
