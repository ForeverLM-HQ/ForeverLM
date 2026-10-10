import Foundation

// MARK: - Ask the Canvas: proposals on the plane (WP-B1)
//
// docs/sensemaking-design.md, "Ask the Canvas". The learner asks a selection
// one of three questions (`CanvasAskTool`); ForeverLM's answer is a set of
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
    ///   reword it.
    @discardableResult
    func keepProposal(_ id: String, at spot: (x: Double, y: Double)? = nil, selectsIdea: Bool = true) -> ProposalKeep {
        let drawnAt = spot ?? askState.positions[id]
        guard let proposal = removeProposal(id)?.proposal else { return .unknown }
        return keep(proposal, at: drawnAt ?? fallbackSpot(for: proposal), selectsIdea: selectsIdea)
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
        for proposal in set.proposals {
            keep(proposal, at: positions[proposal.id] ?? fallbackSpot(for: proposal), selectsIdea: false)
        }
    }

    @discardableResult
    private func keep(_ proposal: KnowledgeMapProposal, at spot: (x: Double, y: Double), selectsIdea: Bool) -> ProposalKeep {
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
            // one burst, so one undo step.
            guard let id = addEdge(from: from, to: to) else { return .skipped }
            let label = proposal.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !label.isEmpty { relabelEdge(id, to: label) }
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
