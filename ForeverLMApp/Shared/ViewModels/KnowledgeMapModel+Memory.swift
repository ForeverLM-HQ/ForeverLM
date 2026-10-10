import CoreGraphics
import Foundation
import Observation

// MARK: - Memory on the Canvas: what the Canvas holds (docs/knowledge-map-design.md, "Memory on the Canvas")
//
// `KnowledgeMapModel.memory`: the Memory layer's marks, whether it shows,
// and a review in place while one runs. The reads and writes are the view
// model's (`StudioViewModel+CanvasMemory.swift`); the canvas pushes what is
// here to the page (`KnowledgeMapCanvasView+Memory.swift`).

/// The Canvas's Memory layer and its review in place.
@MainActor
@Observable
final class KnowledgeMapMemory {
    /// Whether the layer shows, on this Mac: a view choice, never synced.
    static let layerPreferenceKey = "knowledgeMap.memoryLayer.v1"

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isShown = defaults.bool(forKey: Self.layerPreferenceKey)
    }

    /// Whether the Memory layer shows: off until the learner turns it on.
    var isShown: Bool {
        didSet {
            guard isShown != oldValue else { return }
            defaults.set(isShown, forKey: Self.layerPreferenceKey)
            revision &+= 1
        }
    }

    /// What Memory knows about each card the Canvas can draw, by ref: the
    /// kept cards anchored to its sources and how they stand
    /// (`CanvasMemoryMarks`). A card with no kept card has no mark.
    private(set) var marks: [String: KnowledgeMapMemoryMark] = [:]
    /// Bumped when the layer or the marks change, so the canvas tells the
    /// page once.
    private(set) var revision = 0
    @ObservationIgnored private var readRequest = 0

    /// A read of the marks: only the latest one is stored, so a burst of
    /// answers reads once and an older read never lands over a newer one.
    func beginRead() -> Int {
        readRequest &+= 1
        return readRequest
    }

    func finishRead(_ request: Int, marks: [String: KnowledgeMapMemoryMark]) {
        guard request == readRequest, marks != self.marks else { return }
        self.marks = marks
        revision &+= 1
    }

    /// What the renderer's Memory layer receives (`setMemory`).
    var payload: KnowledgeMapMemoryPayload {
        KnowledgeMapMemoryPayload(enabled: isShown, marks: marks)
    }

    // MARK: Review in place

    /// The review in place running on the Canvas; nil when none is.
    private(set) var review: KnowledgeMapReview?
    /// A review is being read and dealt.
    var isStartingReview = false
    /// Cards are being drafted from what the learner made sense of.
    var isMakingCards = false
    /// Escape pressed in the page during a review (`reviewEscape`): the pane
    /// ends the review.
    private(set) var escapeRequests = 0

    func begin(_ review: KnowledgeMapReview) {
        self.review = review
    }

    /// Ends the review, returning it for what must follow (its answers
    /// landing, the marks read again).
    @discardableResult
    func end() -> KnowledgeMapReview? {
        let ended = review
        review = nil
        return ended
    }

    func requestEscape() {
        escapeRequests &+= 1
    }

    /// Changes whenever the page must hear something: the layer, the marks,
    /// a review starting, moving to another card or ending. The pane passes
    /// it to the canvas, so its update runs.
    var syncToken: Int {
        var hasher = Hasher()
        hasher.combine(revision)
        hasher.combine(review?.id)
        hasher.combine(review?.focusKey)
        return hasher.finalize()
    }
}

/// One review in place: the card review's own sitting
/// (`MemoryCardSessionModel`, which writes each answer as the card review
/// does), each card's anchor on the Canvas, and where the page draws the card
/// asked now.
@MainActor
@Observable
final class KnowledgeMapReview: Identifiable {
    /// What the page is told of the card asked now: its anchor, where the
    /// card is in the round (`index`, from 0) and how many the round holds.
    struct Focus: Equatable, Sendable {
        let ref: String
        let index: Int
        let total: Int

        var object: [String: Any] { ["ref": ref, "index": index, "total": total] }
    }

    let session: MemoryCardSessionModel
    let kind: CanvasReviewDeal.Kind
    /// Each card's anchor, by item id: the Canvas card it came through.
    let anchors: [String: String]
    /// The window whose Canvas runs the review.
    let windowID: UUID
    /// The sitting's key (`MemoryCardSitting.key`).
    let id: String

    init(session: MemoryCardSessionModel, kind: CanvasReviewDeal.Kind, anchors: [String: String], windowID: UUID) {
        self.id = session.id
        self.session = session
        self.kind = kind
        self.anchors = anchors
        self.windowID = windowID
    }

    /// Where the page draws the anchor of the card asked now, in the
    /// canvas's points from its top left; nil while it is not drawn.
    private(set) var anchorRect: CGRect?
    /// Bumped to fly the Canvas to the card again: its pane changed size.
    private(set) var refocusRequest = 0
    /// Rounds dealt so far: the first, then each Again.
    private(set) var round = 0

    /// The anchor of the card asked now; at a round's end, of its last card.
    var focusRef: String? {
        let sitting = session.sitting
        if let card = sitting.current { return anchors[card.itemID] }
        return sitting.cards.last.flatMap { anchors[$0.itemID] }
    }

    var focus: Focus? {
        guard let ref = focusRef else { return nil }
        let sitting = session.sitting
        return Focus(ref: ref, index: min(sitting.position, max(0, sitting.cardCount - 1)), total: sitting.cardCount)
    }

    /// Changes when the page must fly again: another card, another round,
    /// or a refocus.
    var focusKey: String? {
        guard let focus else { return nil }
        return "\(round)|\(focus.index)|\(focus.ref)|\(refocusRequest)"
    }

    /// What the page reported for `ref`. A report for a card no longer
    /// asked (a flight that settled late) is left out.
    func setAnchor(ref: String, rect: CGRect?) {
        guard ref == focusRef else { return }
        if anchorRect != rect { anchorRect = rect }
    }

    /// The card asked changed: a rect drawn for another anchor is stale.
    func cardChanged(from previousRef: String?) {
        if focusRef != previousRef { anchorRect = nil }
    }

    /// The round's forgotten cards again (Again for the N), nothing written.
    func againForForgotten() {
        let previous = focusRef
        guard session.sitting.isRoundOver, session.sitting.forgottenCount > 0 else { return }
        session.reviewForgotten()
        round &+= 1
        cardChanged(from: previous)
    }

    /// Fly to the card again, where the pane now has room for the question.
    func refocus() {
        refocusRequest &+= 1
    }
}
