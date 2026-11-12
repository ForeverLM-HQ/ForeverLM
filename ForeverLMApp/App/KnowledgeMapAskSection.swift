import SwiftUI

// MARK: - Ask the Canvas in the pane (WP-B1, docs/sensemaking-design.md)
//
// The inspector's Ask menu: Bridge, Connect, Gaps, a Mind Map and a Question
// Map ask ForeverLM about the selected cards (or a region's), and the answer
// arrives on the plane as proposals drawn dotted, with a banner to keep or
// dismiss them all; Atlas, Review Here and Make Cards hand the same cards to
// the shapes that own them. Written Faces sits with the view controls. One
// menu, not a block of buttons; a single clip does not show it.

/// The inspector's Ask over the selected cards, or a selected region's.
struct KnowledgeMapAskSection: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?

    /// The cards asked about: the selection, or the cards a region holds.
    let refs: [String]
    /// The notebook of a selected notebook's frame, which an Atlas is made for.
    var notebookID: String? = nil

    private var map: KnowledgeMapModel { vm.knowledgeMap(in: windowState) }

    var body: some View {
        let placedCount = refs.filter { map.layout.placements[$0] != nil }.count
        VStack(alignment: .leading, spacing: 6) {
            if let tool = map.asking {
                KnowledgeMapAskProgress(tool: tool)
            }
            Menu {
                askItem(.bridge, enabled: !refs.isEmpty, help: "Find sources in your library that connect these cards")
                askItem(
                    .connect,
                    enabled: placedCount >= 2,
                    help: placedCount >= 2 ? "Propose arrows: how these cards bear on each other" : "Connect needs two cards placed on the canvas"
                )
                askItem(.gaps, enabled: !refs.isEmpty, help: "Name the research questions these cards leave open")
                askItem(.summarize, enabled: !refs.isEmpty, help: "Sum these cards up as one Idea, with a note of a few sentences")
                // One source with text can be taken apart into its concepts.
                if let sourceID = breakDownSourceID {
                    askItem(.breakDown, enabled: vm.knowledgeMapSourceHasText(sourceID), help: "Lay this source out as 5 to 12 concept Ideas with arrows among them, in a region named for it")
                }
                askItem(
                    .mindMap,
                    enabled: asksTree,
                    help: !asksTree
                        ? "A mind map reads up to \(CanvasAskService.maximumCards) cards: select fewer"
                        : hangsFromIdea
                            ? "Hang a mind map from this Idea: the topics that follow from it, as branches to keep or set aside"
                            : "Draw what these cards say as a mind map: a root, its branches and leaves, each one to keep or set aside"
                )
                askItem(
                    .questionMap,
                    enabled: asksTree,
                    help: !asksTree
                        ? "A question map reads up to \(CanvasAskService.maximumCards) cards: select fewer"
                        : hangsFromIdea
                            ? "Break this Idea into the questions that would answer it, narrower at every level"
                            : "Break what these cards are about into questions, each narrower than the one above it"
                )
                Divider()
                Button("Atlas") { vm.openAtlas(topic: nil, itemRefs: refs, notebookID: notebookID) }
                    .help("Lay the topic of these cards out as concepts, from the big picture down")
                Button("Review Here") { vm.canvasReviewHere(refs: refs) }
                    .help("Review the Memory cards of these cards here, on the canvas")
                Button("Make Cards") { vm.canvasMakeCards(refs: refs, edgeIDs: vm.knowledgeMapEdgeIDs(among: refs)) }
                    .help("Draft Memory cards from these ideas and arrows into To Check")
            } label: {
                Text("Ask")
            }
            .menuStyle(.button)
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.10))
            .fixedSize()
            .disabled(refs.isEmpty)
            .help("Ask ForeverLM about these cards")
            .accessibilityIdentifier("knowledgeMap.ask.menu")
        }
        .zoomedSystemFont(size: 12)
    }

    /// A Mind Map or Question Map reads 1 to 24 cards.
    private var asksTree: Bool {
        (1...CanvasAskService.maximumCards).contains(refs.count)
    }

    /// Whether a tree hangs from the card asked about: the one card is an
    /// Idea on the canvas.
    private var hangsFromIdea: Bool {
        guard refs.count == 1, KnowledgeMap.ItemRef(refs[0])?.kind == .idea else { return false }
        return map.layout.placements[refs[0]] != nil
    }

    /// The one source a Break Down takes: the only card asked about, when it
    /// is a source.
    private var breakDownSourceID: String? {
        guard refs.count == 1, let item = KnowledgeMap.ItemRef(refs[0]), item.kind == .source else { return nil }
        return item.id
    }

    private func askItem(_ tool: CanvasAskTool, enabled: Bool, help: String) -> some View {
        Button(tool.menuTitle) { vm.canvasAsk(tool, refs: refs) }
            .disabled(!enabled)
            .help(help)
            .accessibilityIdentifier("knowledgeMap.ask.\(tool.rawValue)")
    }
}

/// An Ask under way, quietly, with Stop.
struct KnowledgeMapAskProgress: View {
    @Environment(StudioViewModel.self) private var vm

    let tool: CanvasAskTool

    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            Text("✦ " + Self.doing(tool))
                .zoomedSystemFont(size: 12)
                .italic()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .textSelection(.disabled)
            Spacer(minLength: 8)
            Button("Stop") { vm.stopCanvasAsk() }
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.10))
                .zoomedSystemFont(size: 12)
                .help("Stop asking; nothing is proposed")
                .accessibilityIdentifier("knowledgeMap.ask.stop")
        }
    }

    static func doing(_ tool: CanvasAskTool) -> String {
        switch tool {
        case .bridge: return "Bridging…"
        case .connect: return "Connecting…"
        case .gaps: return "Finding gaps…"
        case .summarize: return "Summarizing…"
        case .breakDown: return "Breaking it down…"
        case .mindMap: return "Mapping…"
        case .questionMap: return "Breaking into questions…"
        }
    }
}

/// Over the plane while proposals show, as the lens banner is: what was asked
/// and how many proposals wait, with Keep All and Dismiss All. While an Ask
/// runs with the inspector closed, its progress shows here instead.
struct KnowledgeMapProposalBanner: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?

    /// Whether an Ask's progress shows here: the inspector, which shows it, is
    /// closed.
    let showsProgress: Bool

    var body: some View {
        let map = vm.knowledgeMap(in: windowState)
        VStack(alignment: .leading, spacing: 6) {
            if let set = map.proposals {
                HStack(spacing: 10) {
                    Text("✦")
                        .foregroundStyle(Color.purple.opacity(0.8))
                    Text(set.tool.title)
                        .zoomedSystemFont(size: 12, weight: .semibold)
                        .lineLimit(1)
                    Text(set.proposals.count == 1 ? "1 proposal" : "\(set.proposals.count) proposals")
                        .zoomedSystemFont(size: 12)
                        .foregroundStyle(.secondary)
                    Button("Keep All") { map.keepAllProposals() }
                        .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.10))
                        .help("Keep every proposal where it is drawn: sources placed, arrows drawn, questions written as ideas")
                        .accessibilityIdentifier("knowledgeMap.proposals.keepAll")
                    Button("Dismiss All") { map.dismissAllProposals() }
                        .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.10))
                        .help("Set them all aside; the next \(set.tool.title) will not offer them again")
                        .accessibilityIdentifier("knowledgeMap.proposals.dismissAll")
                }
                .textSelection(.disabled)
            }
            if showsProgress, let tool = map.asking {
                KnowledgeMapAskProgress(tool: tool)
                    .frame(width: 220)
            }
        }
        .zoomedSystemFont(size: 12)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

/// Written Faces, beside the caption's switch: what each source says, written
/// for every zoom, in place of its cut title. Remembered on this Mac. It shows
/// while on; the canvas's Show ▸ turns it on, and the pane writes the faces
/// when it does.
struct KnowledgeMapFacesToggle: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?

    var body: some View {
        @Bindable var map = vm.knowledgeMap(in: windowState)
        Toggle(isOn: $map.showsWrittenFaces) {
            Image(systemName: "text.below.photo")
                .zoomedSystemFont(size: 14)
                .frame(width: 32, height: 28)
                .foregroundStyle(map.showsWrittenFaces ? Color.accentColor : Color.primary.opacity(0.8))
        }
        .toggleStyle(.button)
        .buttonStyle(.hoverWash(cornerRadius: 8, inset: 0, opacity: 0.10))
        .help(map.showsWrittenFaces ? "Show sources by their titles" : "Show what each source says, written for every zoom")
        .accessibilityLabel("Written Faces")
        .accessibilityIdentifier("knowledgeMap.writtenFaces")
    }
}
