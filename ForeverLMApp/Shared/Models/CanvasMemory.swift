import Foundation

// MARK: - Memory on the Canvas (docs/knowledge-map-design.md, "Memory on the Canvas")
//
// The pure rules behind the Canvas's Memory layer and its review in place:
// how the kept cards anchored to a card's sources stand today (a mark),
// which cards Review Here deals, and the order it visits them in. Foundation
// only, so the tests pin them without a store or a screen. The reads are
// `KnowledgeStore.canvasMemoryRead` (the Memory pane's own read of the kept
// cards), the writes the card review's sitting (`MemoryCardSessionModel`).

/// One kept card as the Canvas reads it: the sources it is anchored on, its
/// schedule (`MemoryTutorScheduler`, from its whole history), its last answer
/// and when it was kept.
struct CanvasMemoryCard: Equatable, Sendable {
    let itemID: String
    let sourceIDs: Set<String>
    let schedule: MemorySchedule
    /// The latest graded answer; nil for a card never answered.
    let lastAnsweredAt: Date?
    let keptAt: Date

    init(itemID: String, sourceIDs: Set<String>, schedule: MemorySchedule, lastAnsweredAt: Date?, keptAt: Date) {
        self.itemID = itemID
        self.sourceIDs = sourceIDs
        self.schedule = schedule
        self.lastAnsweredAt = lastAnsweredAt
        self.keptAt = keptAt
    }

    /// The active items as cards, each scheduled from its whole history. The
    /// caller passes only items with a face (`KnowledgeStore.canvasMemoryRead`).
    static func cards(items: [MemoryItem], attempts: [MemoryAttempt], calendar: Calendar = .current) -> [CanvasMemoryCard] {
        let attemptsByItemID = Dictionary(grouping: attempts, by: \.memoryItemID)
        var seen = Set<String>()
        return items.compactMap { item in
            guard item.status == .active, seen.insert(item.id).inserted else { return nil }
            let history = attemptsByItemID[item.id] ?? []
            return CanvasMemoryCard(
                itemID: item.id,
                sourceIDs: Set(item.sources.map(\.sourceID)),
                schedule: MemoryTutorScheduler.schedule(item: item, attempts: history, calendar: calendar),
                lastAnsweredAt: history
                    .filter { $0.gradeState == .graded && $0.scheduleRating != nil }
                    .map(\.attemptedAt)
                    .max(),
                keptAt: item.createdAt
            )
        }
    }
}

/// How the kept cards behind a card on the Canvas stand today
/// (`KnowledgeMapMemoryMark`).
///
/// - **due**: a card whose answer counts now: due by now, or kept and never
///   answered, which waits for its first review. A card due later today is
///   not due yet: its answer now would be shown and not written
///   (`MemoryCardQueue.answerCounts`), so counting it would leave the mark
///   standing after a review in place.
/// - **fading**: due, and overdue by more than two days.
/// - **solid**: answered, and scheduled after now.
/// - **dusty**: at least half fading, or nothing answered (nor kept) in 30
///   days.
///
/// `cards` is `due + solid`; `fading` is part of `due`.
enum CanvasMemoryMarks {
    static let fadingAfter: TimeInterval = 2 * MemoryTutorScheduler.secondsPerDay
    static let dustyAfter: TimeInterval = 30 * MemoryTutorScheduler.secondsPerDay

    /// Whether the card's answer counts now.
    static func isDue(_ card: CanvasMemoryCard, now: Date) -> Bool {
        card.schedule.isNew || card.schedule.dueAt <= now
    }

    static func isFading(_ card: CanvasMemoryCard, now: Date) -> Bool {
        !card.schedule.isNew && now.timeIntervalSince(card.schedule.dueAt) > fadingAfter
    }

    /// The mark of a set of cards; nil when there is none.
    static func mark(of cards: [CanvasMemoryCard], now: Date) -> KnowledgeMapMemoryMark? {
        guard !cards.isEmpty else { return nil }
        var due = 0
        var fading = 0
        var lastAnswered: Date?
        var lastActivity = Date.distantPast
        for card in cards {
            if isDue(card, now: now) { due += 1 }
            if isFading(card, now: now) { fading += 1 }
            if let answered = card.lastAnsweredAt {
                lastAnswered = max(lastAnswered ?? answered, answered)
            }
            lastActivity = max(lastActivity, card.lastAnsweredAt ?? card.keptAt)
        }
        let dusty = fading * 2 >= cards.count || now.timeIntervalSince(lastActivity) > dustyAfter
        return KnowledgeMapMemoryMark(
            cards: cards.count,
            due: due,
            fading: fading,
            solid: cards.count - due,
            lastReviewedAt: lastAnswered,
            dusty: dusty
        )
    }

    /// One mark per key, over the cards anchored on any of the key's sources:
    /// a source's own, an Idea's evidence, a Doc's citations, a region's
    /// cards. A card anchored on two of a key's sources counts once. A key
    /// with no card is left out.
    static func marks(
        for groups: [String: Set<String>],
        cards: [CanvasMemoryCard],
        now: Date
    ) -> [String: KnowledgeMapMemoryMark] {
        var cardsBySource: [String: [Int]] = [:]
        for (index, card) in cards.enumerated() {
            for sourceID in card.sourceIDs { cardsBySource[sourceID, default: []].append(index) }
        }
        var result: [String: KnowledgeMapMemoryMark] = [:]
        for (key, sourceIDs) in groups {
            var indices = Set<Int>()
            for sourceID in sourceIDs { indices.formUnion(cardsBySource[sourceID] ?? []) }
            guard !indices.isEmpty else { continue }
            if let mark = mark(of: indices.sorted().map { cards[$0] }, now: now) {
                result[key] = mark
            }
        }
        return result
    }

    /// The sources behind each card the Canvas can draw: a source card its
    /// own source, an Idea its evidence sources (its links of kind source), a
    /// Doc the sources it cites. Each id is joined by the id the learner's
    /// kept cards stand on (`canonical`: a team's copy resolves to the
    /// learner's own source).
    static func refSources(content: KnowledgeMapContent, canonical: (String) -> String) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        func ids(_ id: String) -> Set<String> { [id, canonical(id)] }
        for node in content.nodes where node.kind == KnowledgeMap.ItemKind.source.rawValue {
            guard let ref = KnowledgeMap.ItemRef(node.ref) else { continue }
            result[node.ref, default: []].formUnion(ids(ref.id))
        }
        for link in content.links where link.kind == "idea" || link.kind == "doc" || link.kind == "clip" {
            guard let owner = KnowledgeMap.ItemRef(link.a), owner.kind != .source,
                  let target = KnowledgeMap.ItemRef(link.b), target.kind == .source else { continue }
            result[link.a, default: []].formUnion(ids(target.id))
        }
        return result
    }
}

/// What the renderer's Memory layer receives (`setMemory`, docs/knowledge-map-design.md):
/// whether it shows, and each card's mark by ref. `lastReviewedAt` is
/// milliseconds since 1970, what a page's `Date` takes.
struct KnowledgeMapMemoryPayload: Encodable, Equatable {
    struct Mark: Encodable, Equatable {
        var cards: Int
        var due: Int
        var fading: Int
        var solid: Int
        var dusty: Bool
        var lastReviewedAt: Double?
    }

    var enabled: Bool
    var marks: [String: Mark]

    init(enabled: Bool, marks: [String: KnowledgeMapMemoryMark]) {
        self.enabled = enabled
        self.marks = marks.mapValues { mark in
            Mark(
                cards: mark.cards,
                due: mark.due,
                fading: mark.fading,
                solid: mark.solid,
                dusty: mark.dusty,
                lastReviewedAt: mark.lastReviewedAt.map { ($0.timeIntervalSince1970 * 1000).rounded() }
            )
        }
    }
}

/// Which kept cards Review Here deals over the Canvas cards it was asked on,
/// and in what order (docs/knowledge-map-design.md, "Review in place").
///
/// - The cards whose answers count, first: due by now — most overdue first —
///   then those never answered, oldest kept first, at most `dueLimit`. The
///   sitting is learner-started practice, so a card kept today is asked too
///   and its answer is its first (`MemoryCardQueue.answerCounts` with
///   practice).
/// - When none is due: a practice of the weakest cards (lowest stability),
///   at most `practiceLimit`. Their answers are shown and not written, so a
///   review in place never stretches an interval.
///
/// The cards are then asked as a tour of the Canvas (`tour`): each card at
/// the placed card it came through, nearest card next.
enum CanvasReviewDeal {
    static let practiceLimit = 12
    static let dueLimit = 50

    enum Kind: String, Equatable, Sendable {
        /// Cards whose answers count: due, or never answered.
        case due
        /// Nothing due: the weakest cards, practice only.
        case practice
    }

    struct Dealt: Equatable, Sendable {
        let kind: Kind
        /// In the order they are asked.
        let entries: [MemoryCardQueue.Entry]
        /// Each card's anchor, by item id: the Canvas card it came through.
        let anchors: [String: String]

        static let empty = Dealt(kind: .due, entries: [], anchors: [:])
    }

    /// Each card's anchor among `refs` (in the caller's order of preference:
    /// a source's own card first, then the Ideas and Docs it hangs under):
    /// the first whose sources hold one of the card's anchors. A card none
    /// holds has no anchor and is not dealt.
    static func anchors(
        items: [MemoryItem],
        refs: [(ref: String, sourceIDs: Set<String>)]
    ) -> [String: String] {
        var result: [String: String] = [:]
        for item in items {
            let anchored = Set(item.sources.map(\.sourceID))
            if let match = refs.first(where: { !$0.sourceIDs.isDisjoint(with: anchored) }) {
                result[item.id] = match.ref
            }
        }
        return result
    }

    /// The deal over the kept cards with an anchor, in tour order.
    static func deal(
        items: [MemoryItem],
        attempts: [MemoryAttempt],
        anchors: [String: String],
        positions: [String: (x: Double, y: Double)],
        now: Date,
        calendar: Calendar = .current
    ) -> Dealt {
        let attemptsByItemID = Dictionary(grouping: attempts, by: \.memoryItemID)
        var seen = Set<String>()
        var overdue: [MemoryCardQueue.Entry] = []
        var unanswered: [MemoryCardQueue.Entry] = []
        var later: [MemoryCardQueue.Entry] = []
        for item in items where item.status == .active && anchors[item.id] != nil {
            guard seen.insert(item.id).inserted else { continue }
            let schedule = MemoryTutorScheduler.schedule(item: item, attempts: attemptsByItemID[item.id] ?? [], calendar: calendar)
            if schedule.isNew {
                unanswered.append(MemoryCardQueue.Entry(item: item, schedule: schedule, bucket: .new, notebookID: nil, daysOverdue: 0))
            } else if schedule.dueAt <= now {
                let days = Int(max(0, now.timeIntervalSince(schedule.dueAt)) / MemoryTutorScheduler.secondsPerDay)
                overdue.append(MemoryCardQueue.Entry(item: item, schedule: schedule, bucket: .due, notebookID: nil, daysOverdue: days))
            } else {
                later.append(MemoryCardQueue.Entry(item: item, schedule: schedule, bucket: .due, notebookID: nil, daysOverdue: 0))
            }
        }
        let kind: Kind
        let chosen: [MemoryCardQueue.Entry]
        if !overdue.isEmpty || !unanswered.isEmpty {
            kind = .due
            let dueFirst = overdue.sorted {
                if $0.schedule.dueAt != $1.schedule.dueAt { return $0.schedule.dueAt < $1.schedule.dueAt }
                return $0.item.id < $1.item.id
            }
            let oldestFirst = unanswered.sorted {
                if $0.item.createdAt != $1.item.createdAt { return $0.item.createdAt < $1.item.createdAt }
                return $0.item.id < $1.item.id
            }
            chosen = Array((dueFirst + oldestFirst).prefix(dueLimit))
        } else {
            kind = .practice
            chosen = Array(later.sorted {
                if $0.schedule.stability != $1.schedule.stability { return $0.schedule.stability < $1.schedule.stability }
                if $0.schedule.dueAt != $1.schedule.dueAt { return $0.schedule.dueAt < $1.schedule.dueAt }
                return $0.item.id < $1.item.id
            }.prefix(practiceLimit))
        }
        let toured = tour(chosen, anchors: anchors, positions: positions)
        var dealtAnchors: [String: String] = [:]
        for entry in toured { dealtAnchors[entry.id] = anchors[entry.id] }
        return Dealt(kind: kind, entries: toured, anchors: dealtAnchors)
    }

    /// The cards as a tour of the Canvas: the cards of one anchor together,
    /// in the order they were dealt; the anchors from the top-left-most
    /// (smallest x + y) to the nearest one not visited yet, and so on. Anchors
    /// with no spot on the plane come last, in the order they first appear.
    static func tour(
        _ entries: [MemoryCardQueue.Entry],
        anchors: [String: String],
        positions: [String: (x: Double, y: Double)]
    ) -> [MemoryCardQueue.Entry] {
        var order: [String] = []
        var byAnchor: [String: [MemoryCardQueue.Entry]] = [:]
        for entry in entries {
            let anchor = anchors[entry.id] ?? ""
            if byAnchor[anchor] == nil { order.append(anchor) }
            byAnchor[anchor, default: []].append(entry)
        }
        var placed = order.filter { positions[$0] != nil }
        let unplaced = order.filter { positions[$0] == nil }
        var visited: [String] = []
        func spot(_ ref: String) -> (x: Double, y: Double) { positions[ref] ?? (0, 0) }
        if let start = placed.min(by: { lhs, rhs in
            let a = spot(lhs), b = spot(rhs)
            if a.x + a.y != b.x + b.y { return a.x + a.y < b.x + b.y }
            if a.y != b.y { return a.y < b.y }
            if a.x != b.x { return a.x < b.x }
            return lhs < rhs
        }) {
            var current = start
            placed.removeAll { $0 == start }
            visited.append(start)
            while !placed.isEmpty {
                let from = spot(current)
                guard let next = placed.min(by: { lhs, rhs in
                    let a = spot(lhs), b = spot(rhs)
                    let da = (a.x - from.x) * (a.x - from.x) + (a.y - from.y) * (a.y - from.y)
                    let db = (b.x - from.x) * (b.x - from.x) + (b.y - from.y) * (b.y - from.y)
                    if da != db { return da < db }
                    return lhs < rhs
                }) else { break }
                placed.removeAll { $0 == next }
                visited.append(next)
                current = next
            }
        }
        return (visited + unplaced).flatMap { byAnchor[$0] ?? [] }
    }
}
