import Foundation

// MARK: - Ask the Canvas: proposals on the plane
//
// docs/sensemaking-design.md, "Ask the Canvas". The learner asks a selection
// one of the questions of `CanvasAskTool`; ForeverLM's answer is a set of
// proposals the renderer draws dotted beside the cards they answer, each the
// learner's to keep or dismiss. Keeping one is the learner's own write, through
// the path their own hands use: a source is placed as a drop places it, an
// arrow drawn as the Arrow tool draws it, a question written as an Idea as the
// Note tool writes one. ForeverLM never places, draws or writes on its own: an
// answer nobody keeps leaves the Canvas exactly as it was. Proposals live in
// memory only.

/// What one Ask of the Canvas needs between the press and the answer, and what
/// this session remembers of the learner's answers to it.
@MainActor
final class KnowledgeMapAskState {
    /// Where the page drew each ghost, by proposal id: its latest
    /// `proposalLayout`, which Keep All places them at.
    var positions: [String: (x: Double, y: Double)] = [:]
    /// What the learner set aside this session, per tool, oldest first: sent
    /// with the next Ask of that tool as what not to propose again.
    var setAside: [CanvasAskTool: [String]] = [:]
    /// The sources set aside from a Bridge this session; never offered again.
    var setAsideSourceIDs: Set<String> = []
    /// The Ask running now. Each Ask takes the next number, and an answer that
    /// arrives under an older number is dropped.
    var task: Task<CanvasAskService.Result, Error>?
    var serial = 0
    /// Writes a kept question as an Idea at a spot on the plane and gives back
    /// its ref: the app's Note path (`StudioViewModel.keepCanvasQuestion`),
    /// installed with the proposals it serves.
    var makeIdea: ((String, (x: Double, y: Double)) async -> String?)?
    /// The same with a note, and with no spot for an Idea that is not placed
    /// yet: a Summarize's and a Break Down's Ideas are written with the note
    /// the model gave them. Installed with the proposals it serves; when it
    /// is there it writes every kept question.
    var writeIdea: ((String, String?, (x: Double, y: Double)?) async -> String?)?
    /// The Ideas being written for kept questions, one after another.
    var ideaWrites: Task<Void, Never>?
    /// The Ideas a tree's proposals became as the learner kept them one at a
    /// time, by proposal id, until the next answer shows: a branch is drawn
    /// between a kept Idea and the Idea it hangs from, which may have been
    /// kept before it, and Keep All hangs what is left from them.
    var keptTreeIdeas: [String: String] = [:]
    /// Cards to select on the page without flying to them, taken by the pane's
    /// canvas on its next push.
    var pendingSelection: [String]?

    /// Most set-aside examples kept per tool.
    static let setAsideLimit = 12

    func takePendingSelection() -> [String]? {
        defer { pendingSelection = nil }
        return pendingSelection
    }
}

extension KnowledgeMapModel {
    /// What keeping one proposal did.
    enum ProposalKeep: Equatable {
        /// A source placed on the plane, by ref.
        case placed(String)
        /// A source already on the plane: left where the learner put it, and
        /// shown there.
        case shown(String)
        /// An arrow drawn, by its id.
        case arrow(String)
        /// A question being written as an Idea.
        case idea
        /// Nothing to keep: its cards are joined already, one is off the plane,
        /// or the card is gone from the library.
        case skipped
        /// No proposal shows with that id.
        case unknown
    }

    // MARK: Showing

    /// Shows an answer in place of the proposals showing. Refused while a lens
    /// shows: the two never show together.
    @discardableResult
    func showProposals(
        _ set: KnowledgeMapProposalSet,
        makeIdea: ((String, (x: Double, y: Double)) async -> String?)?,
        writeIdea: ((String, String?, (x: Double, y: Double)?) async -> String?)? = nil
    ) -> Bool {
        guard lens == nil else { return false }
        askState.positions = [:]
        askState.keptTreeIdeas = [:]
        askState.makeIdea = makeIdea
        askState.writeIdea = writeIdea
        proposals = set.proposals.isEmpty ? nil : set
        proposalsRevision &+= 1
        return true
    }

    func clearProposals() {
        guard proposals != nil else { return }
        proposals = nil
        askState.positions = [:]
        proposalsRevision &+= 1
    }

    // MARK: The page's ghosts

    /// The renderer's messages about its ghosts: where it laid them out, and
    /// the learner keeping or dismissing one.
    func receiveProposalMessage(_ type: String, _ body: [String: Any]) {
        switch type {
        case "proposalLayout":
            var positions: [String: (x: Double, y: Double)] = [:]
            for (id, value) in body["positions"] as? [String: Any] ?? [:] {
                guard let spot = value as? [String: Any],
                      let x = Self.proposalNumber(spot["x"]), let y = Self.proposalNumber(spot["y"]) else { continue }
                positions[id] = (x, y)
            }
            askState.positions = positions
        case "proposalKeep":
            guard let id = body["id"] as? String else { return }
            let spot: (x: Double, y: Double)?
            if let x = Self.proposalNumber(body["x"]), let y = Self.proposalNumber(body["y"]) {
                spot = (x, y)
            } else {
                spot = nil
            }
            keepProposal(id, at: spot)
        case "proposalDismiss":
            if let id = body["id"] as? String { dismissProposal(id) }
        default:
            break
        }
    }

    // MARK: Keeping

    /// Keeps one proposal as the learner's own write, one undo step:
    ///
    /// - a source is placed at `spot` (where it was dropped), else where its
    ///   ghost is drawn; one already on the plane is not moved but shown;
    /// - an arrow is drawn between its two placed cards with its label,
    ///   unless an arrow already joins them;
    /// - a question becomes an Idea at that spot, selected so the learner can
    ///   reword it; a tree's node (Mind Map, Question Map) also has its branch
    ///   drawn when the node it hangs from is the card the tree is rooted on
    ///   or an Idea kept before.
    @discardableResult
    func keepProposal(_ id: String, at spot: (x: Double, y: Double)? = nil, selectsIdea: Bool = true) -> ProposalKeep {
        let drawnAt = spot ?? askState.positions[id]
        let set = proposals
        guard let proposal = removeProposal(id)?.proposal else { return .unknown }
        let at = drawnAt ?? fallbackSpot(for: proposal)
        if let set, let plan = set.plan, plan.tree == true {
            return keepTreeNode(proposal, ofSet: set.id, plan: plan, at: at, selectsIdea: selectsIdea)
        }
        return keep(proposal, at: at, selectsIdea: selectsIdea)
    }

    /// Keeps every proposal still showing, each where its ghost is drawn
    /// (the latest `proposalLayout`); the questions' Ideas are written one
    /// after another. The banner goes.
    func keepAllProposals() {
        guard let set = proposals else { return }
        let positions = askState.positions
        clearProposals()
        // A Break Down is kept whole: its concepts as one block in a region
        // named for the source, and the arrows among them.
        if set.tool == .breakDown, let plan = set.plan, askState.writeIdea != nil {
            keepBreakDown(set, plan: plan)
            return
        }
        // A Mind Map or Question Map is kept whole too: its nodes where the
        // page drew them, joined by their branches.
        if set.tool.drawsTree, let plan = set.plan, plan.tree == true, askState.writeIdea != nil {
            keepTree(set, plan: plan, positions: positions)
            return
        }
        for proposal in set.proposals {
            keep(proposal, at: positions[proposal.id] ?? fallbackSpot(for: proposal), selectsIdea: false)
        }
    }

    /// `onWritten` is given the ref of the Idea a kept question became, once
    /// it is written (a tree draws its branch from it).
    @discardableResult
    private func keep(
        _ proposal: KnowledgeMapProposal,
        at spot: (x: Double, y: Double),
        selectsIdea: Bool,
        onWritten: ((String) -> Void)? = nil
    ) -> ProposalKeep {
        switch proposal.kind {
        case .source:
            guard let ref = proposal.ref, nodesByRef[ref] != nil else { return .skipped }
            if layout.placements[ref] != nil {
                send(.focus(refs: [ref], regionID: nil))
                return .shown(ref)
            }
            place([(ref: ref, x: spot.x.rounded(), y: spot.y.rounded())])
            return .placed(ref)
        case .edge:
            guard let from = proposal.from, let to = proposal.to, from != to,
                  layout.placements[from] != nil, layout.placements[to] != nil,
                  !Self.joined(from, to, in: layout) else { return .skipped }
            // The Arrow tool's path: the arrow, then its label; two writes in
            // one burst, so one undo step. An arrow that supports or
            // contradicts is drawn green or red, as the learner's own For and
            // Against make it.
            guard let id = addEdge(from: from, to: to) else { return .skipped }
            let label = proposal.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !label.isEmpty { relabelEdge(id, to: label) }
            if let stance = proposal.relation.flatMap(KnowledgeMapEdgeStance.init(rawValue:)) { setEdgeStance(id, stance) }
            return .arrow(id)
        case .question:
            let text = proposal.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let note = proposal.note?.trimmingCharacters(in: .whitespacesAndNewlines)
            let makeIdea = askState.makeIdea
            let writeIdea = askState.writeIdea
            guard !text.isEmpty, makeIdea != nil || writeIdea != nil else { return .skipped }
            let before = askState.ideaWrites
            askState.ideaWrites = Task { [weak self] in
                await before?.value
                let ref: String?
                if let writeIdea {
                    ref = await writeIdea(text, note?.isEmpty == false ? note : nil, spot)
                } else {
                    ref = await makeIdea?(text, spot)
                }
                if let ref { onWritten?(ref) }
                if selectsIdea, let ref { self?.selectQuietly([ref]) }
            }
            return .idea
        }
    }

    /// Keeps a whole Break Down, the learner's own write: each concept is
    /// written as an Idea with its note (one after another, with the other
    /// question writes), then all of them are set down as one block of free
    /// space beside the source's card (the middle of the view when it is not
    /// on the canvas) with a region around them named for the source, and the
    /// arrows among them are drawn with their labels. The layout writes follow
    /// each other at once, so they are one Undo step.
    private func keepBreakDown(_ set: KnowledgeMapProposalSet, plan: KnowledgeMapBreakDownPlan) {
        guard let writeIdea = askState.writeIdea else { return }
        let concepts = set.proposals.filter { $0.kind == .question }
        let before = askState.ideaWrites
        askState.ideaWrites = Task { [weak self] in
            await before?.value
            var refs: [String: String] = [:]
            for proposal in concepts {
                let title = proposal.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !title.isEmpty else { continue }
                let note = proposal.note?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let ref = await writeIdea(title, note?.isEmpty == false ? note : nil, nil) { refs[proposal.id] = ref }
            }
            let ordered = concepts.compactMap { refs[$0.id] }
            guard let self, !ordered.isEmpty else { return }
            let center: KnowledgeMapArranging.Spot
            if let spot = self.layout.placements[plan.sourceRef] {
                center = .init(x: spot.x + KnowledgeMap.cardWidth / 2, y: spot.y + KnowledgeMap.cardHeight / 2)
            } else {
                center = self.arrivalCenter()
            }
            let regionID = self.placeBlock(ordered, near: center, regionName: plan.regionName)
            for arrow in plan.arrows {
                guard let from = refs[arrow.from], let to = refs[arrow.to] else { continue }
                // The Arrow tool's path: the arrow, then its label.
                if let id = self.addEdge(from: from, to: to) { self.relabelEdge(id, to: arrow.label) }
            }
            self.selectQuietly(ordered)
            self.send(.focus(refs: regionID == nil ? ordered : [], regionID: regionID))
        }
    }

    /// Keeps a whole Mind Map or Question Map, the learner's own write: each
    /// node still showing is written as an Idea with its note (one after
    /// another, with the other question writes) and set down where its ghost
    /// is drawn, and the branches are drawn as tree arrows, also to Ideas
    /// kept one at a time before. Without a `rootRef` a region named for the
    /// root is drawn round the Ideas and laid out as a tree; with one, the new
    /// Ideas join the tree region that card is in (growing it) and stay free
    /// cards when it is in none. A node whose parent could not be written is
    /// not written. The layout writes follow each other at once, so they are
    /// one Undo step.
    private func keepTree(_ set: KnowledgeMapProposalSet, plan: KnowledgeMapBreakDownPlan, positions: [String: (x: Double, y: Double)]) {
        guard let writeIdea = askState.writeIdea else { return }
        let nodes = set.proposals.filter { $0.kind == .question }
        let showing = Set(nodes.map(\.id))
        let parents = Dictionary(plan.arrows.map { ($0.to, $0.from) }, uniquingKeysWith: { first, _ in first })
        let before = askState.ideaWrites
        askState.ideaWrites = Task { [weak self] in
            await before?.value
            guard let self else { return }
            // Starts from the Ideas kept before: what is left hangs from them.
            var refs = self.askState.keptTreeIdeas
            var written: [(node: KnowledgeMapProposal, ref: String)] = []
            for node in nodes {
                // Nothing hangs from a node that was to be written and was not.
                if let parent = parents[node.id], showing.contains(parent), refs[parent] == nil { continue }
                let title = node.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !title.isEmpty else { continue }
                let note = node.note?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let ref = await writeIdea(title, note?.isEmpty == false ? note : nil, nil) else { continue }
                refs[node.id] = ref
                written.append((node, ref))
            }
            self.setDownTree(written, refs: refs, plan: plan, positions: positions)
        }
    }

    /// The writes of `keepTree` once the Ideas exist: `written` is each node
    /// with its Idea, `refs` every Idea of the tree by proposal id.
    private func setDownTree(
        _ written: [(node: KnowledgeMapProposal, ref: String)],
        refs: [String: String],
        plan: KnowledgeMapBreakDownPlan,
        positions: [String: (x: Double, y: Double)]
    ) {
        guard !written.isEmpty else { return }
        let ordered = written.map(\.ref)
        func end(_ id: String) -> String? { id == plan.rootRef ? id : refs[id] }
        let branches = plan.arrows.compactMap { arrow -> (from: String, to: String)? in
            guard let from = end(arrow.from), let to = end(arrow.to), ordered.contains(from) || ordered.contains(to) else { return nil }
            return (from, to)
        }
        let drawn = written.map { item -> (ref: String, x: Double, y: Double) in
            let spot = positions[item.node.id] ?? fallbackSpot(for: item.node)
            return (item.ref, spot.x.rounded(), spot.y.rounded())
        }
        var regionID: String?
        if let root = plan.rootRef {
            // Where the page has not said where it drew the ghosts, the tree
            // is laid out here from the card.
            let ghostsKnown = written.allSatisfy { positions[$0.node.id] != nil }
            place(ghostsKnown ? drawn : spotsHanging(from: root, refs: ordered, branches: branches))
            for branch in branches { addEdge(from: branch.from, to: branch.to, label: "", tree: true) }
            joinTreeRegion(of: root, adding: ordered, name: plan.regionName)
        } else {
            place(drawn)
            for branch in branches { addEdge(from: branch.from, to: branch.to, label: "", tree: true) }
            // Laying the region out as a tree sets the Ideas in order from the
            // branches, so the spots the ghosts had matter only as its start.
            // The Ideas of this tree kept one at a time before are in it too.
            let earlier = Set(refs.values).subtracting(ordered).filter { layout.placements[$0] != nil }
            // Nodes kept one at a time may have made the mind map already.
            let made = earlier.sorted().lazy.compactMap { self.regionID(containing: $0) }.first { self.layout.regions[$0]?.isTree == true }
            if let id = made {
                growRegion(id, toHold: ordered)
                setRegionLayout(id, KnowledgeMapLayout.treeLayout)
                regionID = id
            } else if let id = makeRegion(around: ordered + earlier.sorted(), name: plan.regionName) {
                setRegionLayout(id, KnowledgeMapLayout.treeLayout)
                regionID = id
            }
        }
        selectQuietly(ordered)
        send(.focus(refs: regionID == nil ? ordered : [], regionID: regionID))
    }

    /// The spots of a tree's Ideas that hang from a card on the canvas when
    /// the page has not said where it drew them: a tidy tree with the card at
    /// its root, which stays where it is.
    private func spotsHanging(from root: String, refs: [String], branches: [(from: String, to: String)]) -> [(ref: String, x: Double, y: Double)] {
        var children: [String: [String]] = [:]
        for branch in branches { children[branch.from, default: []].append(branch.to) }
        var heights: [String: Double] = [:], widths: [String: Double] = [:]
        for ref in [root] + refs { heights[ref] = cardHeight(of: ref); widths[ref] = cardWidth(of: ref) }
        let origin = layout.placements[root].map { KnowledgeMapArranging.Spot(x: $0.x, y: $0.y) } ?? arrivalCenter()
        let laid = KnowledgeMapArranging.tree(root: root, children: children, heights: heights, widths: widths, origin: origin).spots
        let shiftX = origin.x - (laid[root]?.x ?? origin.x), shiftY = origin.y - (laid[root]?.y ?? origin.y)
        return refs.compactMap { ref in laid[ref].map { (ref: ref, x: ($0.x + shiftX).rounded(), y: ($0.y + shiftY).rounded()) } }
    }

    /// Keeps one node of a tree: its Idea written at `spot`, and once the Idea
    /// is there its branches drawn: from the node it hangs from, when that is
    /// the card the tree is rooted on or an Idea kept before, and to the nodes
    /// that hang from it which were kept before it (`keptTreeIdeas`).
    private func keepTreeNode(
        _ proposal: KnowledgeMapProposal,
        ofSet setID: String,
        plan: KnowledgeMapBreakDownPlan,
        at spot: (x: Double, y: Double),
        selectsIdea: Bool
    ) -> ProposalKeep {
        let parent = plan.arrows.first { $0.to == proposal.id }?.from
        let children = plan.arrows.filter { $0.from == proposal.id }.map(\.to)
        return keep(proposal, at: spot, selectsIdea: selectsIdea) { [weak self] ref in
            // The Ask may have moved on to another answer while it was written.
            guard let self, self.proposals == nil || self.proposals?.id == setID else { return }
            let kept = self.askState.keptTreeIdeas
            self.askState.keptTreeIdeas[proposal.id] = ref
            let hung = children.compactMap { kept[$0] }
            for child in hung { self.addEdge(from: ref, to: child, label: "", tree: true) }
            if let parent, let parentRef = parent == plan.rootRef ? parent : kept[parent] {
                self.addEdge(from: parentRef, to: ref, label: "", tree: true)
                self.joinTreeRegion(of: parentRef, adding: [ref] + hung, name: plan.regionName)
            }
        }
    }

    /// Grows the mind-map region a card is in to hold Ideas hung from it. A
    /// card in no mind map gets one around it and them, named `name`: a node
    /// is drawn small only inside a mind map, and Ideas hung from a free card
    /// would be drawn as notes over each other. Its layout is set without
    /// laying the cards out again, so the card stays where the learner put it.
    private func joinTreeRegion(of card: String, adding refs: [String], name: String) {
        if let id = regionID(containing: card), layout.regions[id]?.isTree == true {
            growRegion(id, toHold: refs)
            return
        }
        guard let id = makeRegion(around: [card] + refs, name: name) else { return }
        updateLayout { layout, at in
            guard var region = layout.regions[id] else { return }
            region.layout = KnowledgeMapLayout.treeLayout
            region.at = at
            layout.setRegion(id, region)
        }
    }

    /// Whether an arrow joins two cards, either way round.
    nonisolated static func joined(_ a: String, _ b: String, in layout: KnowledgeMapLayout) -> Bool {
        layout.edges.values.contains { ($0.from == a && $0.to == b) || ($0.from == b && $0.to == a) }
    }

    /// Selects cards here and on the page without flying the camera to them.
    func selectQuietly(_ refs: [String]) {
        selection = refs
        selectedRegionID = nil
        selectedEdgeID = nil
        askState.pendingSelection = refs
    }

    /// Where a ghost is set down when the page has not said where it drew it:
    /// beside the cards it answers.
    private func fallbackSpot(for proposal: KnowledgeMapProposal) -> (x: Double, y: Double) {
        let refs = proposal.near.isEmpty ? (proposals?.anchor ?? []) : proposal.near
        let spots = refs.compactMap { layout.placements[$0] }
        guard let minY = spots.map(\.y).min(), let maxX = spots.map(\.x).max() else {
            return (viewport.center.x - KnowledgeMap.cardWidth / 2, viewport.center.y - KnowledgeMap.cardHeight / 2)
        }
        return (maxX + KnowledgeMap.cardWidth + 60, minY)
    }

    // MARK: Dismissing

    /// The learner sets a proposal aside: it goes, and the next Ask of its
    /// tool is told not to offer it again.
    func dismissProposal(_ id: String) {
        guard let removed = removeProposal(id) else { return }
        rememberSetAside(removed.proposal, tool: removed.tool)
    }

    func dismissAllProposals() {
        guard let set = proposals else { return }
        for proposal in set.proposals { rememberSetAside(proposal, tool: set.tool) }
        clearProposals()
    }

    /// What the next Ask of `tool` is told the learner set aside.
    func setAsideExamples(for tool: CanvasAskTool) -> [String] {
        askState.setAside[tool] ?? []
    }

    private func rememberSetAside(_ proposal: KnowledgeMapProposal, tool: CanvasAskTool) {
        let line: String
        switch proposal.kind {
        case .source:
            guard let ref = proposal.ref else { return }
            if let item = KnowledgeMap.ItemRef(ref), item.kind == .source { askState.setAsideSourceIDs.insert(item.id) }
            line = "“\(title(of: ref))”" + (proposal.why.map { " (offered because: \($0))" } ?? "")
        case .edge:
            guard let from = proposal.from, let to = proposal.to else { return }
            let label = proposal.label ?? proposal.relation ?? ""
            line = "“\(title(of: from))” —\(label.isEmpty ? "" : " \(label)")→ “\(title(of: to))”"
        case .question:
            guard let text = proposal.text, !text.isEmpty else { return }
            line = text
        }
        var lines = askState.setAside[tool] ?? []
        lines.removeAll { $0 == line }
        lines.append(line)
        askState.setAside[tool] = Array(lines.suffix(KnowledgeMapAskState.setAsideLimit))
    }

    /// Takes one proposal out of the set showing; the banner goes with the last.
    private func removeProposal(_ id: String) -> (proposal: KnowledgeMapProposal, tool: CanvasAskTool)? {
        guard var set = proposals, let index = set.proposals.firstIndex(where: { $0.id == id }) else { return nil }
        let proposal = set.proposals.remove(at: index)
        proposals = set.proposals.isEmpty ? nil : set
        askState.positions.removeValue(forKey: id)
        proposalsRevision &+= 1
        return (proposal, set.tool)
    }

    // MARK: Reading the plane for an Ask

    /// The name of the region a card is in: the smallest region holding a
    /// placed card's centre (a notebook's frame by its notebook's name), or the
    /// notebook frame that draws an unplaced card.
    func regionName(holding ref: String) -> String? {
        if let id = regionID(containing: ref) {
            if let notebook = notebook(ofRegion: id) { return notebook.title }
            let name = layout.regions[id]?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? nil : name
        }
        guard layout.placements[ref] == nil else { return nil }
        for id in layout.regions.keys.sorted() {
            if let notebook = notebook(ofRegion: id), notebook.refs.contains(ref) { return notebook.title }
        }
        return nil
    }

    nonisolated static func proposalNumber(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let double as Double: return double
        case let int as Int: return Double(int)
        default: return nil
        }
    }
}
