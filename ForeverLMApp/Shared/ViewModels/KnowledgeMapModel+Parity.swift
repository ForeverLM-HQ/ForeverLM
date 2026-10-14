import Foundation

// MARK: - The Canvas's Heptabase parity build: the model API
// (docs/knowledge-map-design.md, "Heptabase parity build (2026-10-09): the
// contract").
//
// A card's size, fold and colour, an arrow's route and heads, a region's lock
// and layout, Tidy Up and Align on a selection, a check of the layout, and a
// mind map's tree. Each call is one write of the learner's, so one Undo step
// (a burst of calls within `editBurst` is one, as the renderer's own writes
// are). Everything the renderer or an assistant may ask for goes through
// here, so the page and the MCP tools never write the row two ways.

extension KnowledgeMapModel {
    private typealias Spot = KnowledgeMapArranging.Spot

    // MARK: A card's look

    /// Applies edits to the size, fold and colour of placed cards, in one
    /// write: a field left as it is, cleared or set (`KnowledgeMapFieldChange`).
    /// A ref that is not placed is skipped. Returns how many cards changed.
    @discardableResult
    func setPlacementStyle(_ items: [KnowledgeMapPlacementStyle]) -> Int {
        var trial = layout.placements
        for item in items where !item.isKeep {
            guard let placement = trial[item.ref] else { continue }
            trial[item.ref] = placement.styled(by: item)
        }
        let changed = trial.filter { layout.placements[$0.key] != $0.value }.keys.sorted()
        guard !changed.isEmpty else { return 0 }
        updateLayout { row, at in
            for ref in changed {
                guard var placement = trial[ref] else { continue }
                placement.at = at
                row.setPlacement(ref, placement)
            }
        }
        return changed.count
    }

    /// Tints cards with one of the Canvas's colours (`regionColors`), or with
    /// nil gives them the kind's own again.
    @discardableResult
    func setCardColor(_ refs: [String], _ color: String?) -> Int {
        setPlacementStyle(refs.map { .init(ref: $0, color: color.map { .set($0) } ?? .clear) })
    }

    /// Folds cards to their title line, or opens them again.
    @discardableResult
    func setCardFolded(_ refs: [String], _ folded: Bool) -> Int {
        setPlacementStyle(refs.map { .init(ref: $0, folded: folded ? .set(true) : .clear) })
    }

    /// Gives one card a width or a height of its own; nil leaves that one as
    /// it is. A region that holds the card grows to hold it at its new size.
    @discardableResult
    func setCardSize(_ ref: String, w: Double?, h: Double?) -> Bool {
        guard layout.placements[ref] != nil, w != nil || h != nil else { return false }
        let changed = setPlacementStyle([.init(ref: ref, w: w.map { .set($0) } ?? .keep, h: h.map { .set($0) } ?? .keep)])
        guard changed > 0 else { return false }
        // Grown in the same burst of writes, so Undo takes both back.
        growRegions(toHold: [ref])
        return true
    }

    /// Gives cards back the size their kind has: the width and height the
    /// learner set are cleared. Returns how many cards changed.
    @discardableResult
    func fitCardsToContent(_ refs: [String]) -> Int {
        setPlacementStyle(refs.map { .init(ref: $0, w: .clear, h: .clear) })
    }

    // MARK: Arrows

    /// Draws an arrow between two ends, each a placed card or a region
    /// (`region:<regionID>`), with its label and look (its `stance` is
    /// `supports` or `contradicts`). An arrow already drawn between them keeps
    /// what it has and takes what is given (a nil label keeps its label). Nil when it cannot be drawn: an end
    /// is missing or off the map, a card is joined to the region that holds it
    /// (or a region to one it is inside), a tree branch would join a region,
    /// give a card a second parent or close a loop, or the look is not one of
    /// the choices.
    @discardableResult
    func addEdge(
        from: String,
        to: String,
        label: String?,
        tree: Bool = false,
        route: String? = nil,
        dashed: Bool? = nil,
        heads: String? = nil,
        color: String? = nil,
        stance: String? = nil
    ) -> String? {
        guard canJoin(from: from, to: to, tree: tree) else { return nil }
        guard route == nil || KnowledgeMapEdgeRoute(rawValue: route ?? "") != nil,
              heads == nil || KnowledgeMapEdgeHeads(rawValue: heads ?? "") != nil,
              Self.isStanceChoice(stance) else { return nil }
        // No label given keeps the one an arrow already drawn has.
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = layout.edges.first { $0.value.from == from && $0.value.to == to }
        let id = existing?.key ?? "e" + UUID().uuidString.prefix(8).lowercased()
        var edge: KnowledgeMapLayout.Edge = existing?.value ?? .init(from: from, to: to, label: trimmed ?? "", at: 0)
        if let trimmed { edge.label = trimmed }
        if tree { edge.tree = true }
        Self.apply(route: route, dashed: dashed, heads: heads, color: color, stance: stance, to: &edge)
        updateLayout { row, at in
            edge.at = at
            row.setEdge(id, edge)
        }
        return id
    }

    /// Changes an arrow's look: its route (`curve`, `straight`, `elbow`),
    /// whether it is dashed, where its heads are (`end`, `both`, `none`), its
    /// colour (`#RRGGBB`, or an empty string for the usual one), whether it is
    /// a mind-map branch, its label and its stance (`supports` or
    /// `contradicts`; an empty string clears it). Nil leaves a part as it is; a
    /// part set to what an arrow has by default is stored as nothing. Returns
    /// whether the arrow changed (false for an unknown arrow, a value that is
    /// not one of the choices, or a branch that cannot be drawn).
    @discardableResult
    func updateEdgeStyle(
        _ id: String,
        route: String? = nil,
        dashed: Bool? = nil,
        heads: String? = nil,
        color: String? = nil,
        tree: Bool? = nil,
        label: String? = nil,
        stance: String? = nil
    ) -> Bool {
        guard var edge = layout.edges[id] else { return false }
        guard route == nil || KnowledgeMapEdgeRoute(rawValue: route ?? "") != nil,
              heads == nil || KnowledgeMapEdgeHeads(rawValue: heads ?? "") != nil,
              Self.isStanceChoice(stance) else { return false }
        let before = edge
        Self.apply(route: route, dashed: dashed, heads: heads, color: color, stance: stance, to: &edge)
        if let label { edge.label = label.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let tree {
            if tree, !edge.isTree {
                guard canJoin(from: edge.from, to: edge.to, tree: true, replacing: id) else { return false }
                edge.tree = true
            } else if !tree {
                edge.tree = nil
            }
        }
        guard edge != before else { return false }
        updateLayout { row, at in
            edge.at = at
            row.setEdge(id, edge)
        }
        return true
    }

    private static func apply(route: String?, dashed: Bool?, heads: String?, color: String?, stance: String? = nil, to edge: inout KnowledgeMapLayout.Edge) {
        if let route { edge.route = route == KnowledgeMapEdgeRoute.curve.rawValue ? nil : route }
        if let dashed { edge.dashed = dashed ? true : nil }
        if let heads { edge.heads = heads == KnowledgeMapEdgeHeads.end.rawValue ? nil : heads }
        if let color { edge.color = color.isEmpty ? nil : color.uppercased() }
        if let stance { edge.stance = stance.isEmpty ? nil : stance }
    }

    /// Whether a stance asked for is one of the choices: nothing (keep), an
    /// empty string (clear), `supports` or `contradicts`.
    static func isStanceChoice(_ stance: String?) -> Bool {
        guard let stance, !stance.isEmpty else { return true }
        return KnowledgeMapEdgeStance(rawValue: stance) != nil
    }

    /// Whether an arrow from `from` to `to` can be drawn (see `addEdge`).
    /// `replacing` is an arrow that is being changed into this one, not a
    /// second one.
    func canJoin(from: String, to: String, tree: Bool = false, replacing: String? = nil) -> Bool {
        edgeRefusal(from: from, to: to, tree: tree, replacing: replacing) == nil
    }

    /// Why an arrow from `from` to `to` cannot be drawn, in a sentence, or nil
    /// when it can.
    func edgeRefusal(from: String, to: String, tree: Bool = false, replacing: String? = nil) -> String? {
        func name(_ end: String) -> String {
            if let id = KnowledgeMap.regionID(fromRef: end) {
                let region = layout.regions[id]?.name ?? ""
                return "the region \(region.isEmpty ? id : region)"
            }
            return "“\(title(of: end))”"
        }
        guard from != to else { return "An arrow joins two different ends." }
        for end in [from, to] {
            if let id = KnowledgeMap.regionID(fromRef: end) {
                guard layout.regions[id] != nil else { return "No region on the Canvas is \(id)." }
            } else if layout.placements[end] == nil {
                return "\(name(end)) is not on the Canvas; place it first."
            }
        }
        let fromRegion = KnowledgeMap.regionID(fromRef: from), toRegion = KnowledgeMap.regionID(fromRef: to)
        // A card is not joined to the region it is in, nor a region to one
        // around or inside it: the arrow would run along its own frame.
        if let region = toRegion, fromRegion == nil, regionHolds(region, card: from) {
            return "\(name(from)) is inside \(name(to)); an arrow does not join a card to the region that holds it."
        }
        if let region = fromRegion, toRegion == nil, regionHolds(region, card: to) {
            return "\(name(to)) is inside \(name(from)); an arrow does not join a card to the region that holds it."
        }
        if let a = fromRegion, let b = toRegion,
           layout.regionPath(of: a).contains(b) || layout.regionPath(of: b).contains(a) {
            return "\(name(from)) and \(name(to)) are one inside the other; an arrow does not join them."
        }
        guard tree else { return nil }
        // A branch joins two cards, a card has one parent, and a tree has no loop.
        guard fromRegion == nil, toRegion == nil else { return "A mind-map branch joins two cards, never a region." }
        if layout.edges.contains(where: { $0.key != replacing && $0.value.isTree && $0.value.to == to && $0.value.from != from }) {
            return "\(name(to)) already has a parent in the mind map; a card has one."
        }
        var ancestor: String? = from
        var steps = 0
        while let current = ancestor, steps < 10_000 {
            if current == to { return "That branch would close a loop: \(name(to)) is above \(name(from)) already." }
            ancestor = treeParent(of: current)
            steps += 1
        }
        return nil
    }

    /// Whether region `id` holds a placed card by its middle.
    private func regionHolds(_ id: String, card ref: String) -> Bool {
        guard let region = layout.regions[id], let placement = layout.placements[ref] else { return false }
        let middle = Self.regionMiddle(of: placement)
        return Rect(x: region.x, y: region.y, w: region.w, h: region.h).holds(x: middle.x, y: middle.y)
    }

    // MARK: Mind maps

    /// The card a branch leads to `ref` from (a mind-map parent), or nil.
    func treeParent(of ref: String) -> String? { layout.treeParent(of: ref) }

    /// The cards a card's branches lead to, top to bottom as they sit.
    func treeChildren(of ref: String) -> [String] { layout.treeChildren(of: ref) }

    // MARK: Regions

    /// Locks a region, so its cards cannot be dragged nor it moved or resized
    /// by hand until it is unlocked.
    @discardableResult
    func setRegionLocked(_ id: String, _ locked: Bool) -> Bool {
        guard var region = layout.regions[id], region.isLocked != locked else { return false }
        region.locked = locked ? true : nil
        updateLayout { row, at in
            region.at = at
            row.setRegion(id, region)
        }
        return true
    }

    /// The cards of region `id` and the regions inside it: what it holds.
    private func contentBounds(ofRegion id: String) -> Rect? {
        var rects: [Rect] = refsInRegion(id).compactMap { ref in
            layout.placements[ref].map { Rect(x: $0.x, y: $0.y, w: cardWidth(of: ref), h: cardHeight(of: ref)) }
        }
        for inner in layout.nestedRegionIDs(in: id) {
            if let region = layout.regions[inner] { rects.append(Rect(x: region.x, y: region.y, w: region.w, h: region.h)) }
        }
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    /// Fits a region to what it holds: its cards and the regions inside it,
    /// with the room a drawn region leaves (`KnowledgeMapArranging.insetX` on
    /// the sides and below, `insetY` above for its name), never smaller than
    /// 200 by 120. An empty region shrinks to that least size. Returns
    /// whether the region changed.
    @discardableResult
    func fitRegionToContent(_ id: String) -> Bool {
        guard var region = layout.regions[id] else { return false }
        let minimum = KnowledgeMapArranging.minimumRegionSize
        let fitted: Rect
        if let content = contentBounds(ofRegion: id) {
            fitted = Rect(
                x: content.x - KnowledgeMapArranging.insetX,
                y: content.y - KnowledgeMapArranging.insetY,
                w: max(content.w + KnowledgeMapArranging.insetX * 2, minimum.w),
                h: max(content.h + KnowledgeMapArranging.insetY + KnowledgeMapArranging.insetX, minimum.h)
            )
        } else {
            fitted = Rect(x: region.x, y: region.y, w: minimum.w, h: minimum.h)
        }
        guard fitted != Rect(x: region.x, y: region.y, w: region.w, h: region.h) else { return false }
        region.x = fitted.x; region.y = fitted.y; region.w = fitted.w; region.h = fitted.h
        updateLayout { row, at in
            region.at = at
            row.setRegion(id, region)
        }
        return true
    }

    /// Grows a region to hold cards, each with `growMargin` (24) around it.
    /// A region never shrinks here. Returns whether it grew.
    @discardableResult
    func growRegion(_ id: String, toHold refs: [String]) -> Bool {
        guard var region = layout.regions[id] else { return false }
        var rect = Rect(x: region.x, y: region.y, w: region.w, h: region.h)
        for ref in refs {
            guard let placement = layout.placements[ref] else { continue }
            let card = Rect(x: placement.x, y: placement.y, w: cardWidth(of: ref), h: cardHeight(of: ref))
            rect = rect.union(card.inset(by: -KnowledgeMapArranging.growMargin))
        }
        guard rect != Rect(x: region.x, y: region.y, w: region.w, h: region.h) else { return false }
        region.x = rect.x; region.y = rect.y; region.w = rect.w; region.h = rect.h
        updateLayout { row, at in
            region.at = at
            row.setRegion(id, region)
        }
        return true
    }

    /// Grows every region (not a locked one) whose middle holds a card, to
    /// hold it, as a drop does.
    private func growRegions(toHold refs: [String], in row: inout KnowledgeMapLayout, at: Double) {
        for ref in refs {
            guard let placement = row.placements[ref] else { continue }
            let card = Rect(x: placement.x, y: placement.y, w: cardWidth(of: ref), h: cardHeight(of: ref))
            let middle = Self.regionMiddle(of: placement)
            for (id, var region) in row.regions where !region.isLocked {
                let frame = Rect(x: region.x, y: region.y, w: region.w, h: region.h)
                guard frame.holds(x: middle.x, y: middle.y), !frame.holds(card) else { continue }
                let grown = frame.union(card.inset(by: -KnowledgeMapArranging.growMargin))
                region.x = grown.x; region.y = grown.y; region.w = grown.w; region.h = grown.h
                region.at = at
                row.setRegion(id, region)
            }
        }
    }

    /// Grows the regions that hold these cards by their middles to hold them
    /// whole, as a drop does (not a locked region), in one write.
    func growRegions(toHold refs: [String]) {
        var grown = layout
        growRegions(toHold: refs, in: &grown, at: 0)
        guard grown.regions != layout.regions else { return }
        updateLayout { row, at in
            growRegions(toHold: refs, in: &row, at: at)
        }
    }

    /// Lays a region's cards out as a mind map (`"tree"`) or sets them free
    /// (nil or `"free"`). Turning a region into a tree lays its cards out
    /// once, from the tree edges among them, so the stored spots are sensible
    /// (the renderer lays a tree out live from the edges afterwards): the
    /// roots stacked top to bottom, each child 60 right of its parent, and the
    /// region fitted round the tree. Setting it free leaves every card where
    /// it is. Returns whether the region changed.
    @discardableResult
    func setRegionLayout(_ id: String, _ newLayout: String?) -> Bool {
        guard var region = layout.regions[id] else { return false }
        let wanted: String?
        switch newLayout {
        case nil, "free", "": wanted = nil
        case KnowledgeMapLayout.treeLayout: wanted = KnowledgeMapLayout.treeLayout
        default: return false
        }
        guard region.layout != wanted else { return false }
        guard wanted != nil else {
            region.layout = nil
            updateLayout { row, at in
                region.at = at
                row.setRegion(id, region)
            }
            return true
        }
        let members = refsInRegion(id)
        let laid = treeSpots(for: members, origin: Spot(x: region.x + KnowledgeMapArranging.insetX, y: region.y + KnowledgeMapArranging.insetY))
        region.layout = wanted
        if let bounds = laid.bounds {
            region.w = max(bounds.w + KnowledgeMapArranging.insetX * 2, KnowledgeMapArranging.minimumRegionSize.w)
            region.h = max(bounds.h + KnowledgeMapArranging.insetY + KnowledgeMapArranging.insetX, KnowledgeMapArranging.minimumRegionSize.h)
            // A node is held by the middle of a usual card at its spot, so the
            // frame keeps every one of those inside it.
            for spot in laid.spots.values {
                region.w = max(region.w, spot.x.rounded() + Self.usualMiddle.x - region.x)
                region.h = max(region.h, spot.y.rounded() + Self.usualMiddle.y - region.y)
            }
        }
        updateLayout { row, at in
            for (ref, spot) in laid.spots { row.place(ref, x: spot.x.rounded(), y: spot.y.rounded(), at: at) }
            region.at = at
            row.setRegion(id, region)
        }
        return true
    }

    /// The spots a tree layout gives `refs`: their roots (no tree parent among
    /// them) stacked at `origin` in the order they sit now, each with its
    /// branches to the cards among them. An Idea of no size of its own is a
    /// node, measured by its words (`KnowledgeMap.treeNodeSize`) as the page
    /// draws it once the cards are a tree.
    func treeSpots(for refs: [String], origin: KnowledgeMapArranging.Spot) -> (spots: [String: KnowledgeMapArranging.Spot], bounds: KnowledgeMapArranging.Rect?) {
        let members = Set(refs)
        var children: [String: [String]] = [:]
        for ref in refs { children[ref] = layout.treeChildren(of: ref).filter { members.contains($0) } }
        let roots = KnowledgeMapArranging.readingOrder(refs.compactMap { ref -> KnowledgeMapArranging.PlacedRect? in
            guard let placement = layout.placements[ref] else { return nil }
            if let parent = layout.treeParent(of: ref), members.contains(parent) { return nil }
            return (ref, Rect(x: placement.x, y: placement.y, w: cardWidth(of: ref), h: cardHeight(of: ref)))
        }).map(\.ref)
        let rootSet = Set(roots)
        var heights: [String: Double] = [:], widths: [String: Double] = [:]
        for ref in refs {
            let role: KnowledgeMapTreeNodeRole = rootSet.contains(ref) ? .root : (children[ref]?.isEmpty == false ? .branch : .leaf)
            let size = treeSize(of: ref, role: role)
            heights[ref] = size.h
            widths[ref] = size.w
        }
        return KnowledgeMapArranging.forest(roots: roots, children: children, heights: heights, widths: widths, origin: origin)
    }

    /// Turns a mind map into plain cards and arrows: the branches among the
    /// region's cards become arrows (heads at their ends), and the region is
    /// free again, its cards where the tree put them. Returns how many
    /// branches became arrows.
    @discardableResult
    func turnTreeIntoArrows(regionID id: String) -> Int {
        guard var region = layout.regions[id] else { return 0 }
        let members = Set(refsInRegion(id))
        let branches = layout.edges.filter { $0.value.isTree && members.contains($0.value.from) && members.contains($0.value.to) }.keys.sorted()
        guard !branches.isEmpty || region.layout != nil else { return 0 }
        region.layout = nil
        updateLayout { row, at in
            for key in branches {
                guard var edge = row.edges[key] else { continue }
                edge.tree = nil
                edge.at = at
                row.setEdge(key, edge)
            }
            region.at = at
            row.setRegion(id, region)
        }
        return branches.count
    }

    /// How large the region that frames a mind map is: the tree's bounds with
    /// the room a drawn region leaves round them. `titles` are the words of
    /// Ideas the map does not hold yet (by ref), as a tree about to be set
    /// down knows them.
    func treeFrameSize(root: String, children: [String: [String]], titles: [String: String] = [:]) -> (w: Double, h: Double) {
        let flat = flatTree(root: root, children: children, titles: titles)
        return treeFrame(around: flat.laid)
    }

    /// A tree's cards laid out by their sizes as a mind map draws them.
    private func flatTree(
        root: String,
        children: [String: [String]],
        titles: [String: String]
    ) -> (order: [String], laid: (spots: [String: Spot], bounds: Rect)) {
        var order: [String] = []
        var seen: Set<String> = []
        func walk(_ ref: String) {
            guard seen.insert(ref).inserted else { return }
            order.append(ref)
            for child in children[ref] ?? [] { walk(child) }
        }
        walk(root)
        var heights: [String: Double] = [:], widths: [String: Double] = [:]
        for ref in order {
            let role: KnowledgeMapTreeNodeRole = ref == root ? .root : (children[ref]?.isEmpty == false ? .branch : .leaf)
            let size = treeSize(of: ref, role: role, titles: titles)
            heights[ref] = size.h
            widths[ref] = size.w
        }
        return (order, KnowledgeMapArranging.tree(root: root, children: children, heights: heights, widths: widths))
    }

    /// The frame that holds a laid-out tree: its bounds with the room a drawn
    /// region leaves, and wide and tall enough that the middle of a usual
    /// card at each spot (what holds a node in a region) is inside it too.
    private func treeFrame(around laid: (spots: [String: Spot], bounds: Rect)) -> (w: Double, h: Double) {
        var frame = (
            w: laid.bounds.w + KnowledgeMapArranging.insetX * 2,
            h: laid.bounds.h + KnowledgeMapArranging.insetY + KnowledgeMapArranging.insetX
        )
        for spot in laid.spots.values {
            frame.w = max(frame.w, KnowledgeMapArranging.insetX + spot.x.rounded() + Self.usualMiddle.x)
            frame.h = max(frame.h, KnowledgeMapArranging.insetY + spot.y.rounded() + Self.usualMiddle.y)
        }
        return frame
    }

    /// Sets a mind map down in free space as near `center` as it can be, in a
    /// region of its own named `name` with `layout` `"tree"`: the cards laid
    /// out as `KnowledgeMapArranging.tree` does (a card with its children
    /// under `children`), the branches drawn, all in one write. Returns the
    /// region and the branches' edge ids, or nil when there is no card. An
    /// Idea of no size of its own is a node of the map, measured by its words
    /// (`titles` gives those of Ideas the map does not hold yet, by ref).
    @discardableResult
    func placeTree(
        root: String,
        children: [String: [String]],
        near center: KnowledgeMapArranging.Spot,
        regionName: String,
        color: String? = nil,
        notebookID: String? = nil,
        titles: [String: String] = [:]
    ) -> (regionID: String, edgeIDs: [String])? {
        let flat = flatTree(root: root, children: children, titles: titles)
        let order = flat.order
        guard !order.isEmpty else { return nil }
        let frameSize = treeFrame(around: flat.laid)
        let origin = KnowledgeMapArranging.freeOrigin(size: frameSize, near: center, occupied: occupied(excluding: Set(order)))
        let spots = flat.laid.spots.mapValues { Spot(x: (origin.x + KnowledgeMapArranging.insetX + $0.x).rounded(), y: (origin.y + KnowledgeMapArranging.insetY + $0.y).rounded()) }
        let id = Self.newRegionID()
        let tint = color ?? nextRegionColor()
        var edgeIDs: [String] = []
        updateLayout { row, at in
            for (ref, spot) in spots { row.place(ref, x: spot.x, y: spot.y, at: at) }
            row.setRegion(id, .init(
                name: regionName,
                x: origin.x, y: origin.y, w: frameSize.w, h: frameSize.h,
                color: tint, at: at, notebookID: notebookID, layout: KnowledgeMapLayout.treeLayout
            ))
            for parent in order {
                for child in children[parent] ?? [] where spots[child] != nil && child != parent {
                    guard !edgeIDs.contains(where: { row.edges[$0]?.to == child }) else { continue }
                    let key = "e" + UUID().uuidString.prefix(8).lowercased()
                    row.setEdge(key, .init(from: parent, to: child, label: "", at: at, tree: true))
                    edgeIDs.append(key)
                }
            }
        }
        return (id, edgeIDs)
    }

    // MARK: Arranging a selection

    /// The rect a placed card is drawn at, by its own size.
    private func drawnRect(of ref: String) -> KnowledgeMapArranging.PlacedRect? {
        guard let placement = layout.placements[ref] else { return nil }
        return (ref, Rect(x: placement.x, y: placement.y, w: cardWidth(of: ref), h: cardHeight(of: ref)))
    }

    /// The selection's placed cards, each once.
    private func placedRects(_ refs: [String]) -> [KnowledgeMapArranging.PlacedRect] {
        var seen: Set<String> = []
        return refs.compactMap { seen.insert($0).inserted ? drawnRect(of: $0) : nil }
    }

    /// Tidy Up: lays the selected cards out as a grid, a row or a column. The
    /// selection's top left stays; the cards are taken in reading order of
    /// where they sit, each by its own width and height, `gap` (30) apart.
    /// Regions that held a card grow to hold it where it lands. Returns how
    /// many cards moved.
    @discardableResult
    func tidyUp(_ refs: [String], as arrangement: KnowledgeMapArrangement) -> Int {
        arrange(refs, as: arrangement, align: nil)
    }

    /// Align: moves the selected cards to one edge or middle of the
    /// selection's bounds. Returns how many cards moved.
    @discardableResult
    func align(_ refs: [String], _ edge: KnowledgeMapAlignment) -> Int {
        arrange(refs, as: nil, align: edge)
    }

    /// Tidy Up and Align in one write (an arrangement first, then the
    /// alignment of the result), for `arrange_on_canvas`.
    @discardableResult
    func arrange(_ refs: [String], as arrangement: KnowledgeMapArrangement?, align edge: KnowledgeMapAlignment?) -> Int {
        var cards = placedRects(refs)
        guard cards.count > 1 else { return 0 }
        var spots: [String: Spot] = [:]
        func absorb(_ moved: [String: Spot]) {
            for (ref, spot) in moved { spots[ref] = spot }
            cards = cards.map { card -> KnowledgeMapArranging.PlacedRect in
                guard let spot = moved[card.ref] else { return card }
                return (card.ref, Rect(x: spot.x, y: spot.y, w: card.rect.w, h: card.rect.h))
            }
        }
        if let arrangement { absorb(KnowledgeMapArranging.tidied(cards, as: arrangement)) }
        if let edge { absorb(KnowledgeMapArranging.aligned(cards, to: edge)) }
        // A card back where it began is not moved.
        spots = spots.filter { ref, spot in
            guard let original = layout.placements[ref] else { return false }
            return abs(original.x - spot.x) > 0.01 || abs(original.y - spot.y) > 0.01
        }
        guard !spots.isEmpty else { return 0 }
        let room = roomUnder(cards)
        // Cards that all sat in one region keep to it: it grows to hold them
        // where they land (a row laid out from a region's cards ran out of
        // it, 2026-10-14). Cards from several regions, or none, do not.
        // When they are all of its cards (and it holds no region), it fits
        // them, as Fit to Content does: a row left a grid's empty frame.
        let homes = Set(refs.filter { layout.placements[$0] != nil }.map { innermostRegionID(holding: $0) })
        // A card moved out from under it keeps to the region it was in.
        let roomHomes = room.keys.reduce(into: [String: String]()) { homes, ref in homes[ref] = innermostRegionID(holding: ref) }
        let home = homes.count == 1 ? homes.first ?? nil : nil
        let fits = home.map { id in
            layout.nestedRegionIDs(in: id).isEmpty && Set(refsInRegion(id)).isSubset(of: Set(refs))
        } ?? false
        let moved = spots, landed = cards
        updateLayout { row, at in
            for (ref, spot) in moved { row.place(ref, x: spot.x, y: spot.y, at: at) }
            for (ref, spot) in room { row.place(ref, x: spot.x, y: spot.y, at: at) }
            if let home, var region = row.regions[home], !region.isLocked {
                var frame = Rect(x: region.x, y: region.y, w: region.w, h: region.h)
                if fits, let first = landed.first?.rect {
                    let content = landed.dropFirst().reduce(first) { $0.union($1.rect) }
                    let minimum = KnowledgeMapArranging.minimumRegionSize
                    frame = Rect(
                        x: content.x - KnowledgeMapArranging.insetX,
                        y: content.y - KnowledgeMapArranging.insetY,
                        w: max(content.w + KnowledgeMapArranging.insetX * 2, minimum.w),
                        h: max(content.h + KnowledgeMapArranging.insetY + KnowledgeMapArranging.insetX, minimum.h)
                    )
                }
                for card in landed { frame = frame.union(card.rect.inset(by: -KnowledgeMapArranging.growMargin)) }
                if frame != Rect(x: region.x, y: region.y, w: region.w, h: region.h) {
                    region.x = frame.x; region.y = frame.y; region.w = frame.w; region.h = frame.h
                    region.at = at
                    row.setRegion(home, region)
                }
            }
            for (ref, id) in roomHomes.sorted(by: { $0.key < $1.key }) {
                guard var region = row.regions[id], !region.isLocked, let placed = row.placements[ref] else { continue }
                let card = Rect(x: placed.x, y: placed.y, w: cardWidth(of: ref), h: cardHeight(of: ref))
                let was = Rect(x: region.x, y: region.y, w: region.w, h: region.h)
                let frame = was.union(card.inset(by: -KnowledgeMapArranging.growMargin))
                guard frame != was else { continue }
                region.x = frame.x; region.y = frame.y; region.w = frame.w; region.h = frame.h
                region.at = at
                row.setRegion(id, region)
            }
            growRegions(toHold: (Array(moved.keys) + Array(room.keys)).sorted(), in: &row, at: at)
        }
        return moved.count
    }

    /// The smallest region holding the card by its middle, as the renderer
    /// counts a card in a region; nil for a card on the open plane.
    private func innermostRegionID(holding ref: String) -> String? {
        guard let placement = layout.placements[ref] else { return nil }
        let middle = Self.regionMiddle(of: placement)
        return layout.regions
            .filter { Rect(x: $0.value.x, y: $0.value.y, w: $0.value.w, h: $0.value.h).holds(x: middle.x, y: middle.y) }
            .min { $0.value.w * $0.value.h < $1.value.w * $1.value.h }?.key
    }

    /// The cards an arrangement now covers, moved down out from under it,
    /// keeping their places to one another: a row laid out across the
    /// canvas hid the cards in its way (2026-10-14, a canvas built by
    /// speaking). A card in a folded region (not drawn) or a locked one stays.
    private func roomUnder(_ arranged: [KnowledgeMapArranging.PlacedRect]) -> [String: Spot] {
        let refs = Set(arranged.map(\.ref))
        let folded = layout.regions.values.filter(\.isCollapsed).map { Rect(x: $0.x, y: $0.y, w: $0.w, h: $0.h) }
        let covered = layout.placements.keys.sorted().compactMap { ref -> KnowledgeMapArranging.PlacedRect? in
            guard !refs.contains(ref), lockedRegionID(holding: ref) == nil, let card = drawnRect(of: ref) else { return nil }
            guard !folded.contains(where: { $0.holds(x: card.rect.midX, y: card.rect.midY) }) else { return nil }
            return arranged.contains { $0.rect.inset(by: 2).intersects(card.rect) } ? card : nil
        }
        guard let top = covered.map(\.rect.y).min(), let bottom = arranged.map(\.rect.maxY).max() else { return [:] }
        // Down below the arrangement, and further down while that lands them
        // on another card, so they never cover one in turn.
        let pushed = Set(covered.map(\.ref))
        let staying = layout.placements.keys.compactMap { ref -> Rect? in
            refs.contains(ref) || pushed.contains(ref) ? nil : drawnRect(of: ref)?.rect
        } + arranged.map(\.rect)
        var shift = bottom + KnowledgeMapArranging.gap - top
        for _ in 0..<40 {
            let landed = covered.map { Rect(x: $0.rect.x, y: $0.rect.y + shift, w: $0.rect.w, h: $0.rect.h) }
            guard let blocker = staying.filter({ other in landed.contains { $0.intersects(other.inset(by: -KnowledgeMapArranging.gap / 2)) } })
                .map(\.maxY).max() else { break }
            let lowestTop = landed.map(\.y).min() ?? 0
            shift += blocker + KnowledgeMapArranging.gap - lowestTop
        }
        return Dictionary(uniqueKeysWithValues: covered.map { ($0.ref, Spot(x: $0.rect.x, y: ($0.rect.y + shift).rounded())) })
    }

    // MARK: Checking the layout

    /// What is wrong with the layout: cards drawn over one another, a card
    /// half outside the region its middle is in, an arrow across a card it
    /// does not join, and a region that holds nothing. A card the library no
    /// longer holds is not drawn and is left out.
    func lint() -> [KnowledgeMapLintIssue] {
        var cards: [String: Rect] = [:]
        for (ref, placement) in layout.placements where nodesByRef.isEmpty || nodesByRef[ref] != nil {
            cards[ref] = Rect(x: placement.x, y: placement.y, w: cardWidth(of: ref), h: cardHeight(of: ref))
        }
        return KnowledgeMapLint.issues(layout: layout, cards: cards, title: { title(of: $0) })
    }

    // MARK: Region ends and locks, for the tools

    /// The region, if any, that is locked and holds the card by its middle:
    /// the learner locked it so its cards stay where they are.
    func lockedRegionID(holding ref: String) -> String? {
        guard let placement = layout.placements[ref] else { return nil }
        let middle = Self.regionMiddle(of: placement)
        return layout.regions.first { _, region in
            region.isLocked && Rect(x: region.x, y: region.y, w: region.w, h: region.h).holds(x: middle.x, y: middle.y)
        }?.key
    }

    // MARK: Chats, canvases and pictures as cards

    /// The cards of the library's other places: a chat is its title and what
    /// it came to (or the day it began), another canvas a shortcut that says
    /// how much it holds, a picture an image of the Images library as tall as
    /// it is at the card's width. A hidden chat, a team's transcript, a link to
    /// a chat elsewhere and a canvas in Trash are not cards. `notebookTitles`
    /// names the notebook a chat or canvas belongs to, where its card waits.
    nonisolated static func shortcutNodes(
        chats: [ReviewSessionRecord],
        canvases: [KnowledgeMapCanvas],
        pictures: [KnowledgeMapPictureCard],
        notebookTitles: [String: String]
    ) -> [KnowledgeMapNode] {
        var nodes: [KnowledgeMapNode] = []
        for chat in chats where !chat.isHidden && !chat.isTeamSnapshot && !chat.isExternalLink {
            let home = chat.goalID.flatMap { notebookTitles[$0] }
            let title = chat.title.trimmingCharacters(in: .whitespacesAndNewlines)
            nodes.append(KnowledgeMapNode(
                ref: KnowledgeMap.ItemRef(kind: .chat, id: chat.id).description,
                kind: "chat",
                type: "chat",
                title: title.isEmpty ? "Untitled chat" : title,
                sub: chatSubtitle(chat),
                detail: home.map { ["In " + $0] } ?? [],
                shore: home ?? "Chats"
            ))
        }
        for canvas in canvases where !canvas.isTrashed {
            let home = canvas.notebookID.flatMap { notebookTitles[$0] }
            nodes.append(KnowledgeMapNode(
                ref: KnowledgeMap.ItemRef(kind: .canvas, id: canvas.id).description,
                kind: "canvas",
                type: "canvas",
                title: canvas.name,
                sub: canvasSubtitle(canvas),
                detail: home.map { ["In " + $0] } ?? [],
                shore: home ?? "Canvases"
            ))
        }
        for picture in pictures {
            nodes.append(KnowledgeMapNode(
                ref: picture.ref,
                kind: "picture",
                type: "picture",
                title: picture.title,
                sub: "",
                detail: [],
                shore: "Pictures",
                h: KnowledgeMap.pictureHeight(aspect: picture.aspect)
            ))
        }
        return nodes
    }

    /// What a chat card says under its title: the start of its summary when
    /// it has one, else the day it began.
    nonisolated static func chatSubtitle(_ chat: ReviewSessionRecord) -> String {
        if let summary = chat.summary?.split(whereSeparator: \.isNewline).first
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }), !summary.isEmpty {
            return String(summary.prefix(140))
        }
        return chat.createdAt.formatted(date: .abbreviated, time: .omitted)
    }

    /// What a canvas card says under its name: "12 cards · 3 regions".
    nonisolated static func canvasSubtitle(_ canvas: KnowledgeMapCanvas) -> String {
        let cards = "\(canvas.cardCount) \(canvas.cardCount == 1 ? "card" : "cards")"
        let regions = "\(canvas.regionCount) \(canvas.regionCount == 1 ? "region" : "regions")"
        return cards + " · " + regions
    }
}
