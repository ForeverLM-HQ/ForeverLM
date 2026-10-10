import Foundation

// Reading a whole book on the phone. An EPUB book is imported as one source per
// chapter, and the reader scrolls through the book as one document: it opens the
// chapter the learner tapped, then adds the chapter after it as the reader nears
// the end of what is on the page and the chapter before it as the reader nears the
// top. Chapters stay the unit everything is stored in — the resume position, the
// depth reached, the end reached, highlights — so the page reports which chapter is
// on screen rather than a position in the book.
//
// This file is the pure part: which chapters are on the page and which one comes
// next, when a chapter counts as read to its end, what the page reports, and the
// steps that bring the page up to date. The page's own script is
// `MobileBookPageScript` (MobileReaderText.swift), the loading is
// `MobileSourceReaderViewModel`, and the steps run in `MobileReaderWebView`.

/// One end of what the page holds.
enum MobileBookEdge: String, Sendable, CaseIterable {
    case start
    case end
}

/// What the page shows at one end of its chapters.
enum MobileBookEdgeState: String, Sendable {
    /// There is more of the book that way; nothing is being fetched yet.
    case idle
    case loading
    /// The chapter that way could not be fetched; the page offers Try Again.
    case failed
    /// The book begins (or ends) here, so there is nothing to show.
    case bookEnd = "end"

    /// Every state but `bookEnd` keeps the same height on the page, so a spinner
    /// or a retry line can come and go without moving the text beside it.
    var isCollapsed: Bool { self == .bookEnd }
}

/// A place in the book: how far through one chapter, in the measure a single
/// chapter's reader has always saved (0 with the chapter's top at the top of the
/// screen, 1 with its end at the bottom).
struct MobileBookReadingPoint: Equatable, Sendable {
    let chapterID: String
    let fraction: Double
}

// MARK: - The chapters on the page

/// Which of a book's chapters are on the page. They are always one unbroken run of
/// the book, grown a chapter at a time at either end, and never more than
/// `maximumLoadedChapters`: a chapter's document carries its pictures inline and can
/// run to megabytes, so a reader who scrolls through half the book lets go of the
/// chapters far behind them.
struct MobileBookWindow: Equatable, Sendable {
    static let maximumLoadedChapters = 5

    /// The whole book, in reading order.
    let chapterIDs: [String]
    private(set) var loaded: ClosedRange<Int>

    /// nil when `openedID` is not one of the book's chapters.
    init?(chapterIDs: [String], openingAt openedID: String) {
        guard let index = chapterIDs.firstIndex(of: openedID) else { return nil }
        self.chapterIDs = chapterIDs
        self.loaded = index...index
    }

    var loadedIDs: [String] { Array(chapterIDs[loaded]) }

    var reachesStart: Bool { loaded.lowerBound == 0 }
    var reachesEnd: Bool { loaded.upperBound == chapterIDs.count - 1 }

    func reaches(_ edge: MobileBookEdge) -> Bool {
        edge == .start ? reachesStart : reachesEnd
    }

    func contains(_ chapterID: String) -> Bool {
        loadedIDs.contains(chapterID)
    }

    func isBookStart(_ chapterID: String) -> Bool {
        chapterIDs.first == chapterID
    }

    /// The chapter that would be added at `edge`, or nil at the book's own end.
    func neighbor(at edge: MobileBookEdge) -> String? {
        switch edge {
        case .start:
            return reachesStart ? nil : chapterIDs[loaded.lowerBound - 1]
        case .end:
            return reachesEnd ? nil : chapterIDs[loaded.upperBound + 1]
        }
    }

    /// Adds the neighbour at `edge` and returns it; nil when the book ends there.
    @discardableResult
    mutating func extend(_ edge: MobileBookEdge) -> String? {
        guard let id = neighbor(at: edge) else { return nil }
        switch edge {
        case .start: loaded = (loaded.lowerBound - 1)...loaded.upperBound
        case .end: loaded = loaded.lowerBound...(loaded.upperBound + 1)
        }
        return id
    }

    /// Lets go of chapters at the far end from `edge` — the one just extended — until
    /// no more than the maximum are loaded. The chapter on screen and the one either
    /// side of it are always kept, so a reader turning back finds the text there.
    /// Returns the chapters let go, nearest the far end first.
    mutating func trim(keeping currentID: String?, after edge: MobileBookEdge) -> [String] {
        guard let currentID, let current = chapterIDs.firstIndex(of: currentID), loaded.contains(current) else {
            return []
        }
        var dropped: [String] = []
        while loaded.count > Self.maximumLoadedChapters {
            switch edge {
            case .end:
                guard loaded.lowerBound < current - 1 else { return dropped }
                dropped.append(chapterIDs[loaded.lowerBound])
                loaded = (loaded.lowerBound + 1)...loaded.upperBound
            case .start:
                guard loaded.upperBound > current + 1 else { return dropped }
                dropped.append(chapterIDs[loaded.upperBound])
                loaded = loaded.lowerBound...(loaded.upperBound - 1)
            }
        }
        return dropped
    }
}

// MARK: - Reaching a chapter's end

/// When reading a chapter counts as reaching its end, which is what records it as
/// read: its fraction climbs to the end from below it while this reader is open.
/// Scrolling up out of one chapter shows the last lines of the one before it, and
/// that is not having read it; reading back down through them is. A chapter the
/// learner chose to open — from the list, or from Contents — counts from its
/// start, the way a single chapter always has. Each chapter reports once.
struct MobileBookEndTracker: Sendable {
    private var lastFractions: [String: Double] = [:]
    private var reachedEndIDs: Set<String> = []

    mutating func begin(_ chapterID: String) {
        lastFractions[chapterID] = 0
    }

    /// True the one time `chapterID` reaches its end.
    mutating func observe(_ chapterID: String, fraction: Double) -> Bool {
        guard fraction.isFinite else { return false }
        let previous = lastFractions[chapterID]
        lastFractions[chapterID] = fraction
        guard !reachedEndIDs.contains(chapterID),
              MobileReadingCompletion.reachedEnd(fraction),
              let previous,
              !MobileReadingCompletion.reachedEnd(previous) else {
            return false
        }
        reachedEndIDs.insert(chapterID)
        return true
    }
}

// MARK: - What the page reports

/// The page's reading report: the chapter under the reading line, a quarter of the
/// way down the screen, and how far through it the reader is; every chapter with
/// some of it on screen; the first and last chapter the page holds; and whether the
/// reader is near either end of them.
struct MobileBookReadingReport: Equatable, Sendable {
    struct Visible: Equatable, Sendable {
        let chapterID: String
        let fraction: Double
    }

    let chapterID: String
    let fraction: Double
    let visible: [Visible]
    let firstChapterID: String
    let lastChapterID: String
    let isNearStart: Bool
    let isNearEnd: Bool

    var point: MobileBookReadingPoint {
        MobileBookReadingPoint(chapterID: chapterID, fraction: fraction)
    }

    init(
        chapterID: String,
        fraction: Double,
        visible: [Visible],
        firstChapterID: String,
        lastChapterID: String,
        isNearStart: Bool,
        isNearEnd: Bool
    ) {
        self.chapterID = chapterID
        self.fraction = fraction
        self.visible = visible
        self.firstChapterID = firstChapterID
        self.lastChapterID = lastChapterID
        self.isNearStart = isNearStart
        self.isNearEnd = isNearEnd
    }

    /// Reads the page's `{type: 'reading', …}` message; nil for anything else.
    init?(message: Any) {
        guard let body = message as? [String: Any],
              body["type"] as? String == "reading",
              let chapterID = body["chapter"] as? String, !chapterID.isEmpty,
              let fraction = Self.fraction(body["fraction"]),
              let first = body["first"] as? String,
              let last = body["last"] as? String else {
            return nil
        }
        let visible = (body["visible"] as? [[String: Any]] ?? []).compactMap { entry -> Visible? in
            guard let id = entry["chapter"] as? String, !id.isEmpty,
                  let fraction = Self.fraction(entry["fraction"]) else { return nil }
            return Visible(chapterID: id, fraction: fraction)
        }
        self.init(
            chapterID: chapterID,
            fraction: fraction,
            visible: visible,
            firstChapterID: first,
            lastChapterID: last,
            isNearStart: body["nearStart"] as? Bool ?? false,
            isNearEnd: body["nearEnd"] as? Bool ?? false
        )
    }

    private static func fraction(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let fraction = number.doubleValue
        guard fraction.isFinite else { return nil }
        return min(max(fraction, 0), 1)
    }
}

/// Everything the book page says to the app.
enum MobileBookPageEvent: Equatable, Sendable {
    case reading(MobileBookReadingReport)
    /// The learner pressed Try Again at a failed end.
    case retry(MobileBookEdge)

    init?(message: Any) {
        guard let body = message as? [String: Any], let type = body["type"] as? String else { return nil }
        switch type {
        case "reading":
            guard let report = MobileBookReadingReport(message: body) else { return nil }
            self = .reading(report)
        case "retry":
            guard let edge = (body["edge"] as? String).flatMap(MobileBookEdge.init(rawValue:)) else { return nil }
            self = .retry(edge)
        default:
            return nil
        }
    }
}

// MARK: - What the page should hold

/// The book page as the view model wants it: the chapters on it in reading order,
/// what each end shows, and the text size. `MobileBookPageSync` turns the
/// difference between this and what the page holds into steps for the page.
struct MobileBookPage: Sendable {
    struct Chapter: Equatable, Sendable {
        let id: String
        /// The chapter's own markup, sanitized, or its synced text as paragraphs.
        let bodyHTML: String
        /// The book's first chapter has no chapter break above it.
        let isBookStart: Bool
    }

    /// A Contents jump to a chapter already on the page: a scroll, not a reload.
    struct ScrollRequest: Equatable, Sendable {
        let token: Int
        let chapterID: String
    }

    /// Bumped when the page is built afresh: when the reader opens, and when
    /// Contents jumps to a chapter that is not on the page.
    let generation: Int
    /// Where the reader is put when this generation's page first fills.
    let restore: MobileBookReadingPoint
    var chapters: [Chapter]
    var startState: MobileBookEdgeState
    var endState: MobileBookEdgeState
    var fontScale: Double
    var scrollRequest: ScrollRequest?

    func state(at edge: MobileBookEdge) -> MobileBookEdgeState {
        edge == .start ? startState : endState
    }

    mutating func setState(_ state: MobileBookEdgeState, at edge: MobileBookEdge) {
        switch edge {
        case .start: startState = state
        case .end: endState = state
        }
    }
}

/// What the page holds, as far as its web view knows.
struct MobileBookDOMState: Equatable, Sendable {
    var chapterIDs: [String]
    var startState: MobileBookEdgeState
    var endState: MobileBookEdgeState
    /// nil until the page has been told a size: a freshly loaded page is always
    /// told one, whatever its stylesheet was written with.
    var fontScale: Double?
    var scrollToken: Int?

    /// `MobileReaderText.bookDocumentHTML` as loaded: no chapters yet, and the
    /// spinner at the end where the opened chapter will appear.
    static let freshShell = MobileBookDOMState(
        chapterIDs: [],
        startState: .idle,
        endState: .loading,
        fontScale: nil,
        scrollToken: nil
    )
}

/// One step for the page (`window.foreverlmBook.apply`).
enum MobileBookPageOperation: Equatable, Sendable {
    case insert(MobileBookPage.Chapter, at: MobileBookEdge)
    case remove(chapterID: String, at: MobileBookEdge)
    case edge(MobileBookEdge, MobileBookEdgeState)
    case fontScale(Double)
    case scroll(MobileBookReadingPoint)

    /// A step that changes how tall the page is above the reader. The page holds
    /// the text still across it, but a web view cannot move its scroll while the
    /// finger is on it or a fling is running, so these wait for the scroll to rest.
    func movesTextAbove(from dom: MobileBookDOMState) -> Bool {
        switch self {
        case .insert(_, let edge), .remove(_, let edge):
            return edge == .start
        case .edge(let edge, let state):
            return edge == .start && state.isCollapsed != dom.startState.isCollapsed
        case .fontScale, .scroll:
            return false
        }
    }

    /// The step as the page script reads it. `fontSize` turns a text scale into
    /// the stylesheet's body size in points.
    func payload(fontSize: (Double) -> Double) -> [String: Any] {
        switch self {
        case .insert(let chapter, let edge):
            return [
                "op": "insert",
                "edge": edge.rawValue,
                "id": chapter.id,
                "html": chapter.bodyHTML,
                "bookStart": chapter.isBookStart,
            ]
        case .remove(let chapterID, let edge):
            return ["op": "remove", "edge": edge.rawValue, "id": chapterID]
        case .edge(let edge, let state):
            return ["op": "edge", "edge": edge.rawValue, "state": state.rawValue]
        case .fontScale(let scale):
            return ["op": "font", "px": fontSize(scale)]
        case .scroll(let point):
            return ["op": "scroll", "id": point.chapterID, "fraction": point.fraction]
        }
    }
}

struct MobileBookPagePlan: Equatable, Sendable {
    let operations: [MobileBookPageOperation]
    /// What the page holds once `operations` have run.
    let resultingState: MobileBookDOMState
    /// Steps that would move text above the reader were held back because the page
    /// is being scrolled; plan again once it rests.
    let deferredStartChanges: Bool
    /// The page's chapters share none with the wanted ones, which only a fresh page
    /// can fix.
    let needsReload: Bool
    /// `restore` is among the steps.
    let performsRestore: Bool
}

enum MobileBookPageSync {
    /// The steps that turn `dom` into `page`. `restore` is where a freshly loaded
    /// page puts the reader once its chapter is on it. `allowsStartChanges` is false
    /// while the page is being scrolled; steps that would move the text above the
    /// reader then wait (`MobileBookPageOperation.movesTextAbove`).
    static func plan(
        from dom: MobileBookDOMState,
        to page: MobileBookPage,
        restore: MobileBookReadingPoint?,
        allowsStartChanges: Bool
    ) -> MobileBookPagePlan {
        let wanted = page.chapters.map(\.id)
        let wantedSet = Set(wanted)
        let held = dom.chapterIDs
        let chaptersByID = Dictionary(page.chapters.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var operations: [MobileBookPageOperation] = []
        if held.isEmpty {
            operations += page.chapters.map { .insert($0, at: .end) }
        } else {
            guard let firstShared = held.firstIndex(where: wantedSet.contains),
                  let lastShared = held.lastIndex(where: wantedSet.contains),
                  let wantedFirst = wanted.firstIndex(of: held[firstShared]),
                  let wantedLast = wanted.firstIndex(of: held[lastShared]) else {
                return MobileBookPagePlan(
                    operations: [],
                    resultingState: dom,
                    deferredStartChanges: false,
                    needsReload: true,
                    performsRestore: false
                )
            }
            // Let go first, then add: nearest the shared run first at the start, so
            // each new chapter goes in directly above the one after it.
            operations += held[..<firstShared].reversed().map { .remove(chapterID: $0, at: .start) }
            operations += held[(lastShared + 1)...].map { .remove(chapterID: $0, at: .end) }
            operations += wanted[..<wantedFirst].reversed().compactMap { id in
                chaptersByID[id].map { .insert($0, at: .start) }
            }
            operations += wanted[(wantedLast + 1)...].compactMap { id in
                chaptersByID[id].map { .insert($0, at: .end) }
            }
        }
        if page.startState != dom.startState {
            operations.append(.edge(.start, page.startState))
        }
        if page.endState != dom.endState {
            operations.append(.edge(.end, page.endState))
        }

        var deferred = false
        if !allowsStartChanges {
            let kept = operations.filter { !$0.movesTextAbove(from: dom) }
            deferred = kept.count != operations.count
            operations = kept
        }

        var result = dom
        result.chapterIDs = applying(operations, to: dom.chapterIDs)
        for operation in operations {
            if case .edge(let edge, let state) = operation {
                if edge == .start { result.startState = state } else { result.endState = state }
            }
        }

        if dom.fontScale.map({ abs($0 - page.fontScale) > 0.0001 }) ?? true {
            operations.append(.fontScale(page.fontScale))
            result.fontScale = page.fontScale
        }

        let present = Set(result.chapterIDs)
        if let request = page.scrollRequest, request.token != dom.scrollToken, present.contains(request.chapterID) {
            operations.append(.scroll(MobileBookReadingPoint(chapterID: request.chapterID, fraction: 0)))
            result.scrollToken = request.token
        }
        var performsRestore = false
        if let restore, present.contains(restore.chapterID) {
            operations.append(.scroll(restore))
            performsRestore = true
        }

        return MobileBookPagePlan(
            operations: operations,
            resultingState: result,
            deferredStartChanges: deferred,
            needsReload: false,
            performsRestore: performsRestore
        )
    }

    private static func applying(_ operations: [MobileBookPageOperation], to chapterIDs: [String]) -> [String] {
        var ids = chapterIDs
        for operation in operations {
            switch operation {
            case .remove(let id, _):
                ids.removeAll { $0 == id }
            case .insert(let chapter, let edge):
                guard !ids.contains(chapter.id) else { continue }
                if edge == .start { ids.insert(chapter.id, at: 0) } else { ids.append(chapter.id) }
            case .edge, .fontScale, .scroll:
                continue
            }
        }
        return ids
    }
}
