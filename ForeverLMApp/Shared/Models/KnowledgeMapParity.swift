import Foundation

// MARK: - The Canvas's Heptabase parity build: what a card and an arrow can
// carry, how a selection is tidied, and what a check of the layout finds
// (docs/knowledge-map-design.md, "Heptabase parity build (2026-10-09): the
// contract"). Foundation only, so the unit tests run it as the Mac does.

// MARK: Editing a placement's look

/// One field of a placement's style in an edit: left as it is, cleared back
/// to the kind's own, or set. A missing key from the page is `.keep` and a
/// `null` is `.clear`.
enum KnowledgeMapFieldChange<Value: Equatable & Sendable>: Equatable, Sendable {
    case keep
    case clear
    case set(Value)

    /// What a stored optional field becomes under this change.
    func applied(to current: Value?) -> Value? {
        switch self {
        case .keep: return current
        case .clear: return nil
        case .set(let value): return value
        }
    }

    var isKeep: Bool {
        if case .keep = self { return true }
        return false
    }
}

/// An edit of one placed card's size, fold, colour, page, words and marks
/// (`KnowledgeMapModel.setPlacementStyle`).
struct KnowledgeMapPlacementStyle: Equatable, Sendable {
    var ref: String
    var w: KnowledgeMapFieldChange<Double> = .keep
    var h: KnowledgeMapFieldChange<Double> = .keep
    var folded: KnowledgeMapFieldChange<Bool> = .keep
    var color: KnowledgeMapFieldChange<String> = .keep
    /// The page a source shows as its card (`Placement.page`).
    var page: KnowledgeMapFieldChange<Int> = .keep
    /// The learner's words under a card (`Placement.annotation`).
    var annotation: KnowledgeMapFieldChange<String> = .keep
    /// An Idea drawn as words (`Placement.plain`).
    var plain: KnowledgeMapFieldChange<Bool> = .keep
    /// A question Idea marked answered (`Placement.answered`).
    var answered: KnowledgeMapFieldChange<Bool> = .keep

    /// Whether the edit changes nothing.
    var isKeep: Bool {
        w.isKeep && h.isKeep && folded.isKeep && color.isKeep && page.isKeep && annotation.isKeep && plain.isKeep && answered.isKeep
    }
}

extension KnowledgeMapLayout.Placement {
    /// This placement with `style` applied: a width and a height kept within
    /// what a card may be, a fold that is off stored as nothing, a colour
    /// as the tint `#RRGGBB`, a page of at least 1 (a source's), the words
    /// trimmed and held to their length (any card's but an Idea's), and a
    /// plain or answered mark that is off stored as nothing (an Idea's). The
    /// kind of card is the one `style.ref` names; a field the kind has no use
    /// for is left as it is.
    func styled(by style: KnowledgeMapPlacementStyle) -> KnowledgeMapLayout.Placement {
        var copy = self
        copy.w = style.w.applied(to: w).map { min(max($0, KnowledgeMap.cardWidthRange.lowerBound), KnowledgeMap.cardWidthRange.upperBound).rounded() }
        copy.h = style.h.applied(to: h).map { min(max($0, KnowledgeMap.cardHeightRange.lowerBound), KnowledgeMap.cardHeightRange.upperBound).rounded() }
        copy.folded = style.folded.applied(to: folded).flatMap { $0 ? true : nil }
        copy.color = style.color.applied(to: color).flatMap { $0.isEmpty ? nil : $0.uppercased() }
        guard let kind = KnowledgeMap.ItemRef(style.ref)?.kind else { return copy }
        switch kind {
        case .source:
            copy.page = style.page.applied(to: page).map { max($0, 1) }
            copy.annotation = style.annotation.applied(to: annotation).flatMap(KnowledgeMap.annotation(from:))
        case .idea:
            copy.plain = style.plain.applied(to: plain).flatMap { $0 ? true : nil }
            copy.answered = style.answered.applied(to: answered).flatMap { $0 ? true : nil }
        case .doc, .clip, .page, .canvas, .chat, .picture:
            copy.annotation = style.annotation.applied(to: annotation).flatMap(KnowledgeMap.annotation(from:))
        }
        return copy
    }
}

/// How cards are set down: the look they take on, all of it optional. Used
/// when a card is placed (`place_on_canvas`), as `KnowledgeMapPlacementStyle`
/// is when it already is.
struct KnowledgeMapCardStyle: Equatable, Sendable {
    var w: Double?
    var h: Double?
    var folded: Bool?
    var color: String?
    /// The page a source is set down showing. 0 sets it down as its usual
    /// card, leaving out the page a paper placed for the first time shows
    /// (`KnowledgeMapModel.pageFaceDefault`).
    var page: Int?
    var annotation: String?
    var plain: Bool?
    var answered: Bool?

    var isEmpty: Bool {
        w == nil && h == nil && folded == nil && color == nil && page == nil && annotation == nil && plain == nil && answered == nil
    }

    /// The style as an edit that sets every field it names.
    func edit(for ref: String) -> KnowledgeMapPlacementStyle {
        KnowledgeMapPlacementStyle(
            ref: ref,
            w: w.map { .set($0) } ?? .keep,
            h: h.map { .set($0) } ?? .keep,
            folded: folded.map { .set($0) } ?? .keep,
            color: color.map { .set($0) } ?? .keep,
            page: page.map { $0 == 0 ? .clear : .set($0) } ?? .keep,
            annotation: annotation.map { .set($0) } ?? .keep,
            plain: plain.map { .set($0) } ?? .keep,
            answered: answered.map { .set($0) } ?? .keep
        )
    }
}

// MARK: Arrows

/// An arrow's route, as stored in `Edge.route`; the first is the default.
enum KnowledgeMapEdgeRoute: String, Sendable, CaseIterable {
    case curve, straight, elbow
}

/// Where an arrow's heads are, as stored in `Edge.heads`; the first is the
/// default.
enum KnowledgeMapEdgeHeads: String, Sendable, CaseIterable {
    case end, both, none
}

/// Which side of an argument an arrow is on, as stored in `Edge.stance`: for
/// it (drawn green) or against it (red). An arrow with neither has none.
enum KnowledgeMapEdgeStance: String, Sendable, CaseIterable {
    case supports, contradicts

    /// The stance a relation names, as a Connect proposal's `relation` says
    /// it ("supports", "Contradicts"); nil for any other.
    init?(relation: String?) {
        guard let word = relation?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        self.init(rawValue: word)
    }
}

// MARK: Arranging a selection

/// How Tidy Up lays a selection out.
enum KnowledgeMapArrangement: String, Sendable, CaseIterable {
    case grid, row, column
}

/// Which edge or middle of a selection's bounds Align moves each card to.
enum KnowledgeMapAlignment: String, Sendable, CaseIterable {
    case left, centerX, right, top, centerY, bottom
}

extension KnowledgeMapArranging.Rect {
    var maxX: Double { x + w }
    var maxY: Double { y + h }
    var midX: Double { x + w / 2 }
    var midY: Double { y + h / 2 }

    func union(_ other: KnowledgeMapArranging.Rect) -> KnowledgeMapArranging.Rect {
        let left = min(x, other.x), top = min(y, other.y)
        return .init(x: left, y: top, w: max(maxX, other.maxX) - left, h: max(maxY, other.maxY) - top)
    }

    func inset(by amount: Double) -> KnowledgeMapArranging.Rect {
        .init(x: x + amount, y: y + amount, w: w - amount * 2, h: h - amount * 2)
    }

    /// Whether this rect holds `other` entirely, with half a point of slack.
    func holds(_ other: KnowledgeMapArranging.Rect) -> Bool {
        let slack = 0.5
        return other.x >= x - slack && other.y >= y - slack && other.maxX <= maxX + slack && other.maxY <= maxY + slack
    }

    func holds(x px: Double, y py: Double) -> Bool {
        px >= x && px <= maxX && py >= y && py <= maxY
    }
}

extension KnowledgeMapArranging {
    typealias PlacedRect = (ref: String, rect: Rect)

    /// What a tree leaves between a card's right edge and its children.
    static let treeColumnGap: Double = 60
    /// What a tree leaves between siblings, and between trees stacked in one region.
    static let treeSiblingGap: Double = 24
    /// The least a region may be made (Fit to Content never goes below it).
    static let minimumRegionSize = (w: 200.0, h: 120.0)
    /// What a region grows by past a card it was grown to hold.
    static let growMargin: Double = 24

    /// Cards in reading order: rows from the top, each row left to right. Two
    /// cards are in one row when their tops are less than half a card apart
    /// (`KnowledgeMap.cardHeight / 2`, as the renderer reads them).
    static func readingOrder(_ cards: [PlacedRect]) -> [PlacedRect] {
        let tolerance = KnowledgeMap.cardHeight / 2
        let byTop = cards.sorted { ($0.rect.y, $0.rect.x, $0.ref) < ($1.rect.y, $1.rect.x, $1.ref) }
        var rows: [[PlacedRect]] = []
        var rowTop = 0.0
        for card in byTop {
            if let last = rows.indices.last, card.rect.y - rowTop < tolerance {
                rows[last].append(card)
            } else {
                rows.append([card])
                rowTop = card.rect.y
            }
        }
        return rows.flatMap { $0.sorted { ($0.rect.x, $0.ref) < ($1.rect.x, $1.ref) } }
    }

    /// Where Tidy Up puts `cards`: the selection's top left stays, the cards
    /// are taken in reading order, each by its own width and height, with
    /// `gap` between them. A grid is about half again as wide as tall, as a
    /// drop sets cards down, each column as wide as its widest card and each
    /// row as tall as its tallest. Only the cards that move are returned.
    static func tidied(_ cards: [PlacedRect], as arrangement: KnowledgeMapArrangement) -> [String: Spot] {
        guard cards.count > 1 else { return [:] }
        let anchor = Spot(x: cards.map(\.rect.x).min() ?? 0, y: cards.map(\.rect.y).min() ?? 0)
        let ordered = readingOrder(cards)
        var spots: [Spot] = []
        switch arrangement {
        case .row:
            var x = anchor.x
            for card in ordered {
                spots.append(Spot(x: x, y: anchor.y))
                x += card.rect.w + gap
            }
        case .column:
            var y = anchor.y
            for card in ordered {
                spots.append(Spot(x: anchor.x, y: y))
                y += card.rect.h + gap
            }
        case .grid:
            let cols = max(1, Int((Double(ordered.count) * 1.5).squareRoot().rounded(.up)))
            let lefts = columnLefts(widths: ordered.map(\.rect.w), cols: cols).lefts
            let rows = rowTops(heights: ordered.map(\.rect.h), cols: cols, gap: gap).tops
            for i in ordered.indices {
                spots.append(Spot(x: anchor.x + lefts[i % cols], y: anchor.y + rows[i / cols]))
            }
        }
        var moved: [String: Spot] = [:]
        for (card, spot) in zip(ordered, spots) {
            let target = Spot(x: spot.x.rounded(), y: spot.y.rounded())
            if abs(target.x - card.rect.x) > 0.01 || abs(target.y - card.rect.y) > 0.01 { moved[card.ref] = target }
        }
        return moved
    }

    /// Where Align puts `cards`: each moved to the selection's bounds on one
    /// edge or middle, by its own size. Only the cards that move are returned.
    static func aligned(_ cards: [PlacedRect], to edge: KnowledgeMapAlignment) -> [String: Spot] {
        guard cards.count > 1 else { return [:] }
        let left = cards.map(\.rect.x).min() ?? 0, top = cards.map(\.rect.y).min() ?? 0
        let right = cards.map(\.rect.maxX).max() ?? 0, bottom = cards.map(\.rect.maxY).max() ?? 0
        var moved: [String: Spot] = [:]
        for card in cards {
            var spot = Spot(x: card.rect.x, y: card.rect.y)
            switch edge {
            case .left: spot.x = left
            case .centerX: spot.x = ((left + right) / 2 - card.rect.w / 2).rounded()
            case .right: spot.x = right - card.rect.w
            case .top: spot.y = top
            case .centerY: spot.y = ((top + bottom) / 2 - card.rect.h / 2).rounded()
            case .bottom: spot.y = bottom - card.rect.h
            }
            if abs(spot.x - card.rect.x) > 0.01 || abs(spot.y - card.rect.y) > 0.01 { moved[card.ref] = spot }
        }
        return moved
    }

    // MARK: Mind maps

    /// A tree laid out left to right: the root at `origin`'s left, each
    /// child `treeColumnGap` right of its parent's right edge, siblings
    /// stacked `treeSiblingGap` apart in the order given, a parent centred
    /// on the span of its children, and no two subtrees overlapping. The
    /// spots are cards' top lefts; the bounds are what the tree covers,
    /// starting at `origin`'s top. A node a tree reaches twice is laid once.
    static func tree(
        root: String,
        children: [String: [String]],
        heights: [String: Double],
        widths: [String: Double],
        origin: Spot = Spot(x: 0, y: 0)
    ) -> (spots: [String: Spot], bounds: Rect) {
        var visited: Set<String> = []
        // A subtree as offsets from its root's top left, with how far above
        // the root and below its top it reaches.
        func lay(_ id: String) -> (offsets: [String: Spot], top: Double, bottom: Double) {
            visited.insert(id)
            let height = heights[id] ?? KnowledgeMap.cardHeight
            let width = widths[id] ?? KnowledgeMap.cardWidth
            var kids: [(layout: (offsets: [String: Spot], top: Double, bottom: Double), y: Double, height: Double)] = []
            var cursor = 0.0
            for kid in children[id] ?? [] where !visited.contains(kid) {
                let layout = lay(kid)
                // The kid's reach starts where the last one's ended.
                let y = cursor - layout.top
                kids.append((layout, y, heights[kid] ?? KnowledgeMap.cardHeight))
                cursor += layout.bottom - layout.top + treeSiblingGap
            }
            guard let first = kids.first, let last = kids.last else {
                return ([id: Spot(x: 0, y: 0)], 0, height)
            }
            let middle = (first.y + last.y + last.height) / 2
            let parentTop = middle - height / 2
            var offsets: [String: Spot] = [id: Spot(x: 0, y: 0)]
            var top = 0.0, bottom = height
            for kid in kids {
                for (key, spot) in kid.layout.offsets {
                    offsets[key] = Spot(x: width + treeColumnGap + spot.x, y: kid.y + spot.y - parentTop)
                }
                top = min(top, kid.y + kid.layout.top - parentTop)
                bottom = max(bottom, kid.y + kid.layout.bottom - parentTop)
            }
            return (offsets, top, bottom)
        }
        let laid = lay(root)
        var spots: [String: Spot] = [:]
        var right = origin.x
        for (key, offset) in laid.offsets {
            let spot = Spot(x: origin.x + offset.x, y: origin.y - laid.top + offset.y)
            spots[key] = spot
            right = max(right, spot.x + (widths[key] ?? KnowledgeMap.cardWidth))
        }
        return (spots, Rect(x: origin.x, y: origin.y, w: right - origin.x, h: laid.bottom - laid.top))
    }

    /// Several trees one under another at `origin`'s left, `treeSiblingGap`
    /// apart, in the order of `roots`.
    static func forest(
        roots: [String],
        children: [String: [String]],
        heights: [String: Double],
        widths: [String: Double],
        origin: Spot = Spot(x: 0, y: 0)
    ) -> (spots: [String: Spot], bounds: Rect?) {
        var spots: [String: Spot] = [:]
        var bounds: Rect?
        var y = origin.y
        for root in roots where spots[root] == nil {
            // Cards another tree laid are left to it.
            let pruned = children.mapValues { $0.filter { spots[$0] == nil } }
            let laid = tree(root: root, children: pruned, heights: heights, widths: widths, origin: Spot(x: origin.x, y: y))
            spots.merge(laid.spots) { first, _ in first }
            bounds = bounds.map { $0.union(laid.bounds) } ?? laid.bounds
            y = laid.bounds.maxY + treeSiblingGap
        }
        return (spots, bounds)
    }
}

// MARK: - Checking a layout

/// One thing a check of the Canvas found (`KnowledgeMapModel.lint()`,
/// `lint_canvas`).
struct KnowledgeMapLintIssue: Equatable, Sendable {
    enum Kind: String, Sendable, CaseIterable {
        /// Two cards drawn over one another.
        case overlap
        /// A card whose middle is in a region but whose edge crosses the
        /// region's.
        case cardOutsideRegion
        /// An arrow that runs across a card it does not join.
        case arrowOverCard
        /// A region that holds no card and no region.
        case emptyRegion
    }

    var kind: Kind
    /// The cards the issue is about, as item_ids.
    var refs: [String] = []
    var regionID: String?
    var edgeID: String?
    /// One line saying what is wrong.
    var message: String
}

enum KnowledgeMapLint {
    /// The issues in `layout`, given the rect each drawn card covers (a
    /// card in a region folded up is not drawn, so it is left out of every
    /// check but a region's being empty) and the words that name a card.
    static func issues(
        layout: KnowledgeMapLayout,
        cards: [String: KnowledgeMapArranging.Rect],
        title: (String) -> String
    ) -> [KnowledgeMapLintIssue] {
        typealias Rect = KnowledgeMapArranging.Rect
        let regions = layout.regions.sorted { ($0.value.y, $0.value.x, $0.key) < ($1.value.y, $1.value.x, $1.key) }
        func rect(_ region: KnowledgeMapLayout.Region) -> Rect { Rect(x: region.x, y: region.y, w: region.w, h: region.h) }
        let folded = regions.filter { $0.value.isCollapsed }.map { rect($0.value) }
        let visible = cards
            .filter { entry in !folded.contains { $0.holds(x: entry.value.midX, y: entry.value.midY) } }
            .sorted { ($0.value.x, $0.value.y, $0.key) < ($1.value.x, $1.value.y, $1.key) }
        var issues: [KnowledgeMapLintIssue] = []

        // Cards drawn over one another: swept left to right.
        for (i, a) in visible.enumerated() {
            for b in visible[(i + 1)...] {
                if b.value.x >= a.value.maxX { break }
                guard a.value.inset(by: 0.5).intersects(b.value.inset(by: 0.5)) else { continue }
                let pair = [a.key, b.key].sorted()
                issues.append(.init(
                    kind: .overlap, refs: pair,
                    message: "“\(title(pair[0]))” and “\(title(pair[1]))” overlap."
                ))
            }
        }

        // A card half outside the region its middle is in.
        for (ref, card) in visible.sorted(by: { $0.key < $1.key }) {
            for (id, region) in regions where !region.isCollapsed {
                let frame = rect(region)
                guard frame.holds(x: card.midX, y: card.midY), !frame.holds(card) else { continue }
                issues.append(.init(
                    kind: .cardOutsideRegion, refs: [ref], regionID: id,
                    message: "“\(title(ref))” sits half outside the region “\(region.name.isEmpty ? "Untitled region" : region.name)”."
                ))
            }
        }

        // An arrow across a card it does not join, judged by the route the
        // Canvas draws: a default arrow bends round the cards in its way
        // (`curveRoute`, the renderer's `curveAround`), so it crosses only
        // what no bend clears; a straight or elbow arrow, and one drawn into
        // a brace with others, by the straight line between its ends' middles.
        let visibleRects = Dictionary(visible.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        let braced = bracedEdgeIDs(layout: layout, cards: visibleRects)
        for (id, edge) in layout.edges.sorted(by: { $0.key < $1.key }) where !edge.isTree {
            guard let fromRect = endRect(edge.from, cards: visibleRects, layout: layout),
                  let toRect = endRect(edge.to, cards: visibleRects, layout: layout) else { continue }
            if edge.route == nil || edge.route == KnowledgeMapEdgeRoute.curve.rawValue, !braced.contains(id) {
                let others = visible.filter { $0.key != edge.from && $0.key != edge.to }.map { (ref: $0.key, rect: $0.value) }
                let route = curveRoute(from: fromRect, to: toRect, others: others)
                for ref in crossed(by: route, others: others) {
                    issues.append(.init(
                        kind: .arrowOverCard, refs: [ref], edgeID: id,
                        message: "The arrow from “\(endName(edge.from, layout: layout, title: title))” to “\(endName(edge.to, layout: layout, title: title))” crosses “\(title(ref))”."
                    ))
                }
                continue
            }
            let start = (x: fromRect.midX, y: fromRect.midY), end = (x: toRect.midX, y: toRect.midY)
            // The part of the line outside both ends.
            let leaves = clip(start, end, to: fromRect)?.exit ?? 0
            let arrives = clip(start, end, to: toRect)?.entry ?? 1
            guard leaves < arrives else { continue }
            for (ref, card) in visible.sorted(by: { $0.key < $1.key }) where ref != edge.from && ref != edge.to {
                guard let crossing = clip(start, end, to: card.inset(by: 2), from: leaves, upTo: arrives) else { continue }
                // A graze is not a crossing.
                let length = hypot((crossing.exit - crossing.entry) * (end.x - start.x), (crossing.exit - crossing.entry) * (end.y - start.y))
                guard length > 4 else { continue }
                issues.append(.init(
                    kind: .arrowOverCard, refs: [ref], edgeID: id,
                    message: "The arrow from “\(endName(edge.from, layout: layout, title: title))” to “\(endName(edge.to, layout: layout, title: title))” crosses “\(title(ref))”."
                ))
            }
        }

        // A region that holds nothing: no card, no region inside it. A
        // notebook's frame draws the notebook's own cards, so it is not empty.
        for (id, region) in regions where region.notebookID == nil {
            let frame = rect(region)
            let holdsCard = cards.values.contains { frame.holds(x: $0.midX, y: $0.midY) }
            let holdsRegion = regions.contains { $0.key != id && frame.holds(rect($0.value)) && rect($0.value) != frame }
            guard !holdsCard, !holdsRegion else { continue }
            issues.append(.init(
                kind: .emptyRegion, regionID: id,
                message: "The region “\(region.name.isEmpty ? "Untitled region" : region.name)” holds no cards."
            ))
        }
        return issues
    }

    // MARK: The default arrow's route, as the renderer draws it

    typealias Point = (x: Double, y: Double)
    /// A quadratic curve: start, control point, end.
    typealias Curve = (p: Point, m: Point, q: Point)

    /// The bends the renderer tries, either way, when the gentle one runs
    /// across cards (`CURVE_BENDS` in knowledge-map.js).
    static let curveBends: [Double] = [120, 200, 300, 420]

    /// Where the line from a box's middle toward `toward` leaves the box, 8
    /// off it (`boxEdge`).
    static func boxEdge(_ c: Point, toward o: Point, of b: KnowledgeMapArranging.Rect) -> Point {
        let dx = o.x - c.x, dy = o.y - c.y
        let k = min(abs((b.w / 2 + 8) / (dx == 0 ? 1e-6 : dx)), abs((b.h / 2 + 8) / (dy == 0 ? 1e-6 : dy)), 1)
        return (c.x + dx * k, c.y + dy * k)
    }

    static func point(on curve: Curve, at t: Double) -> Point {
        let u = 1 - t
        return (u * u * curve.p.x + 2 * u * t * curve.m.x + t * t * curve.q.x,
                u * u * curve.p.y + 2 * u * t * curve.m.y + t * t * curve.q.y)
    }

    /// The curve the renderer draws for a default arrow between two boxes
    /// (`curveAround`): a gentle bend unless it runs across `others`, then
    /// the least bend either way that clears them, leaving and meeting its
    /// ends on that side, or, when none clears them, the one crossing fewest.
    static func curveRoute(
        from a: KnowledgeMapArranging.Rect,
        to b: KnowledgeMapArranging.Rect,
        others: [(ref: String, rect: KnowledgeMapArranging.Rect)]
    ) -> Curve {
        let ca: Point = (a.midX, a.midY), cb: Point = (b.midX, b.midY)
        let p = boxEdge(ca, toward: cb, of: a), q = boxEdge(cb, toward: ca, of: b)
        let mx = (p.x + q.x) / 2, my = (p.y + q.y) / 2
        let dx = q.x - p.x, dy = q.y - p.y
        let length = max(hypot(dx, dy), 1)
        func curve(_ bend: Double, outward: Bool) -> Curve {
            let m: Point = (x: mx - dy / length * bend, y: my + dx / length * bend)
            guard outward else { return (p: p, m: m, q: q) }
            let start = boxEdge(ca, toward: m, of: a)
            let end = boxEdge(cb, toward: m, of: b)
            return (p: start, m: m, q: end)
        }
        let steps = Int(min(max(length / 60, 16), 80).rounded())
        let reach = (curveBends.last ?? 0) / 2 + 20
        let near = others.filter {
            $0.rect.x < max(p.x, q.x) + reach && $0.rect.maxX > min(p.x, q.x) - reach
                && $0.rect.y < max(p.y, q.y) + reach && $0.rect.maxY > min(p.y, q.y) - reach
        }
        let first = curve(min(60, length * 0.12), outward: false)
        guard !near.isEmpty else { return first }
        func crossings(_ route: Curve) -> Int {
            (1..<steps).reduce(0) { count, i in
                let at = point(on: route, at: Double(i) / Double(steps))
                return near.contains { at.x > $0.rect.x - 6 && at.x < $0.rect.maxX + 6 && at.y > $0.rect.y - 6 && at.y < $0.rect.maxY + 6 } ? count + 1 : count
            }
        }
        var best = first, fewest = crossings(first)
        if fewest == 0 { return first }
        for size in curveBends {
            for bend in [size, -size] {
                let route = curve(bend, outward: true)
                let n = crossings(route)
                if n == 0 { return route }
                if n < fewest { best = route; fewest = n }
            }
        }
        return best
    }

    /// The cards a drawn curve runs across, a graze aside: sampled every 10
    /// points against each card drawn 2 smaller, as the straight check is.
    private static func crossed(by route: Curve, others: [(ref: String, rect: KnowledgeMapArranging.Rect)]) -> [String] {
        let length = hypot(route.m.x - route.p.x, route.m.y - route.p.y) + hypot(route.q.x - route.m.x, route.q.y - route.m.y)
        let steps = max(16, Int(length / 10))
        var hit: Set<String> = []
        for i in 1..<steps {
            let at = point(on: route, at: Double(i) / Double(steps))
            for other in others where !hit.contains(other.ref) {
                let r = other.rect.inset(by: 2)
                if at.x > r.x && at.x < r.maxX && at.y > r.y && at.y < r.maxY { hit.insert(other.ref) }
            }
        }
        return hit.sorted()
    }

    /// Default arrows the renderer draws into a brace: two or more into one
    /// card from the same side (`bundles`), whose drawn route is the brace's,
    /// not a curve of their own.
    private static func bracedEdgeIDs(layout: KnowledgeMapLayout, cards: [String: KnowledgeMapArranging.Rect]) -> Set<String> {
        var groups: [String: [String]] = [:]
        for (id, edge) in layout.edges where !edge.isTree && (edge.route == nil || edge.route == KnowledgeMapEdgeRoute.curve.rawValue) {
            guard KnowledgeMap.regionID(fromRef: edge.from) == nil, KnowledgeMap.regionID(fromRef: edge.to) == nil,
                  let a = cards[edge.from], let b = cards[edge.to] else { continue }
            let dx = a.midX - b.midX, dy = a.midY - b.midY
            let side = abs(dx) * b.h >= abs(dy) * b.w ? (dx < 0 ? "left" : "right") : (dy < 0 ? "top" : "bottom")
            groups[edge.to + "|" + side, default: []].append(id)
        }
        return Set(groups.values.filter { $0.count > 1 }.flatMap { $0 })
    }

    private static func endRect(_ ref: String, cards: [String: KnowledgeMapArranging.Rect], layout: KnowledgeMapLayout) -> KnowledgeMapArranging.Rect? {
        if let id = KnowledgeMap.regionID(fromRef: ref) {
            guard let region = layout.regions[id], !region.isCollapsed else { return nil }
            return .init(x: region.x, y: region.y, w: region.w, h: region.h)
        }
        return cards[ref]
    }

    private static func endName(_ ref: String, layout: KnowledgeMapLayout, title: (String) -> String) -> String {
        if let id = KnowledgeMap.regionID(fromRef: ref) {
            let name = layout.regions[id]?.name ?? ""
            return name.isEmpty ? "Untitled region" : name
        }
        return title(ref)
    }

    /// Where the segment from `a` to `b`, between the parameters `from` and
    /// `upTo`, is inside `rect`: the parameters it enters and leaves at, or
    /// nil when it never is (Liang–Barsky).
    private static func clip(
        _ a: (x: Double, y: Double), _ b: (x: Double, y: Double), to rect: KnowledgeMapArranging.Rect,
        from: Double = 0, upTo: Double = 1
    ) -> (entry: Double, exit: Double)? {
        var t0 = from, t1 = upTo
        let dx = b.x - a.x, dy = b.y - a.y
        for (p, q) in [(-dx, a.x - rect.x), (dx, rect.maxX - a.x), (-dy, a.y - rect.y), (dy, rect.maxY - a.y)] {
            if p == 0 {
                if q < 0 { return nil }
            } else {
                let t = q / p
                if p < 0 { t0 = max(t0, t) } else { t1 = min(t1, t) }
            }
            if t0 > t1 { return nil }
        }
        return (t0, t1)
    }
}
