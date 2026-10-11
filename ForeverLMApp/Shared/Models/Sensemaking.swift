import Foundation

// MARK: - Sensemaking (docs/sensemaking-design.md)
//
// The vocabulary the sensemaking shapes share: Ask the Canvas, the Atlas,
// Memory on the Canvas, Levels in the Reader and the Canvas's written faces.
// Each shape's own types live beside its code; only what two of them pass
// between each other is here.

/// What a selection on the Canvas can be asked ("Ask the Canvas").
enum CanvasAskTool: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Library sources that connect the selected cards.
    case bridge
    /// Typed arrows between the selected cards.
    case connect
    /// Questions the selected cards leave open.
    case gaps
    /// One Idea that sums the selected cards up: a title and a note of a few
    /// sentences, proposed as a question is and kept as an Idea.
    case summarize
    /// One source taken apart into its concepts: Ideas with a sentence each,
    /// arrows among them, laid out in a region named for the source.
    case breakDown = "break_down"
    /// A topic tree of what the selected cards say: a root, branches and
    /// leaves of a few words each, drawn on the plane as a mind map. Hung from
    /// the card when the one card asked is an Idea on the canvas.
    case mindMap = "mind_map"
    /// The same tree, every node a question: a sub-question narrower than its
    /// parent and a leaf a literature search or an experiment could answer.
    case questionMap = "question_map"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bridge: return "Bridge"
        case .connect: return "Connect"
        case .gaps: return "Gaps"
        case .summarize: return "Summarize"
        case .breakDown: return "Break Down"
        case .mindMap: return "Mind Map"
        case .questionMap: return "Question Map"
        }
    }

    /// What the inspector's Ask menu calls it.
    var menuTitle: String {
        switch self {
        case .summarize: return "Summarize into an Idea"
        case .breakDown: return "Break Down This Source"
        case .mindMap: return "Make a Mind Map"
        case .questionMap: return "Break Into Questions"
        default: return title
        }
    }

    /// Whether the answer is a tree (`KnowledgeMapBreakDownPlan.tree`): the
    /// Mind Map and the Question Map, kept as one branching set of Ideas.
    var drawsTree: Bool { self == .mindMap || self == .questionMap }

    /// The asks `ask_canvas` offers an assistant: an assistant summarizes and
    /// breaks a source down itself, draws a mind map with `build_canvas`'s
    /// `trees`, and writes the Ideas with `build_canvas`.
    static let overMCP: [CanvasAskTool] = [.bridge, .connect, .gaps]
}

/// One thing ForeverLM proposes on the Canvas. It is drawn dotted, beside the
/// cards it answers, until the learner keeps or dismisses it, and it is never
/// stored: keeping it is the learner's own placement, arrow or Idea.
struct KnowledgeMapProposal: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// A library source to place; `ref` is `source:<id>`.
        case source
        /// An arrow between two placed cards: `from`, `to`, `label`.
        case edge
        /// A question to keep as an Idea: `text`.
        case question
    }

    var id: String
    var kind: Kind
    var ref: String?
    var from: String?
    var to: String?
    var label: String?
    /// For an arrow: supports, contradicts, explains, causes, measures,
    /// extends, example or same_question.
    var relation: String?
    var text: String?
    /// One line on why, in ForeverLM's ✦ voice. Shown beside the proposal and
    /// gone once it is kept.
    var why: String?
    /// The asked-about cards this proposal answers; it is set down near them.
    var near: [String]
    /// For a question: the note its Idea is written with (a Summarize's few
    /// sentences, a Break Down concept's or a tree node's one), kept with the
    /// Idea, never drawn on the ghost.
    var note: String?

    init(
        id: String = "p:" + UUID().uuidString.lowercased(),
        kind: Kind,
        ref: String? = nil,
        from: String? = nil,
        to: String? = nil,
        label: String? = nil,
        relation: String? = nil,
        text: String? = nil,
        why: String? = nil,
        near: [String] = [],
        note: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.ref = ref
        self.from = from
        self.to = to
        self.label = label
        self.relation = relation
        self.text = text
        self.why = why
        self.near = near
        self.note = note
    }
}

/// What keeping a whole Break Down or tree writes beyond its Ideas: the region
/// they are laid out in, named for the source (or the tree's root), and the
/// arrows among them. The concepts themselves are the set's question
/// proposals; each arrow names two of their ids. Keeping one concept alone
/// writes just that Idea.
struct KnowledgeMapBreakDownPlan: Codable, Equatable, Sendable {
    struct Arrow: Codable, Equatable, Sendable {
        /// Proposal ids; a rooted tree's first branches start at `rootRef`.
        var from: String
        var to: String
        var label: String
    }

    /// The source broken down (`source:<id>`): the concepts are set down
    /// beside its card when it is on the canvas. For a tree, the first card
    /// asked about.
    var sourceRef: String
    var regionName: String
    var arrows: [Arrow]
    /// A Mind Map or a Question Map: the proposals are the nodes of one tree,
    /// the arrows are its branches (parent to child, labelled ""), and the
    /// page draws the set as a ghost tree. Nil for a Break Down.
    var tree: Bool? = nil
    /// A tree hung from an Idea already on the canvas (`idea:<id>`): the
    /// proposals are what hangs from it, and it is the `from` of the first
    /// branches. Nil when the model wrote the root, which is the one
    /// proposal no arrow leads to.
    var rootRef: String? = nil
}

/// One answer to one Ask: its proposals, and the cards that were asked about.
struct KnowledgeMapProposalSet: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var tool: CanvasAskTool
    var title: String
    var anchor: [String]
    var proposals: [KnowledgeMapProposal]
    var createdAt: Date
    /// A Break Down's region and arrows, or a tree's branches; nil for every
    /// other ask.
    var plan: KnowledgeMapBreakDownPlan? = nil
}

/// What Memory knows about one card on the Canvas ("Memory on the Canvas"):
/// the kept cards anchored to its sources and how they stand today.
struct KnowledgeMapMemoryMark: Codable, Equatable, Sendable {
    /// Kept cards anchored to this card's sources: `due + solid`.
    var cards: Int
    /// Cards whose answer counts now: due by now, or kept and never answered
    /// (which wait for their first review). A card due later today is not due
    /// yet (`CanvasMemoryMarks`).
    var due: Int
    /// Due and overdue by more than two days: being forgotten.
    var fading: Int
    /// Answered and scheduled ahead: holding.
    var solid: Int
    var lastReviewedAt: Date?
    /// Nothing about it reviewed for a long while.
    var dusty: Bool
}

/// Something the learner made sense of, to be remembered: one of their Ideas,
/// an arrow they drew between two cards, an Atlas concept or a term. Cards
/// drafted from it are anchored to quotes from `sourceIDs`, as every card is
/// anchored to a source ("Cards from what you made sense of").
struct SituatedAnchor: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case idea, relation, concept, term
    }

    var kind: Kind
    /// The thought in words: an Idea's sentence, "A — label → B", a concept's
    /// line, a term and its definition.
    var text: String
    /// More around it: an Idea's note, the region it sits in, a concept's
    /// paragraph.
    var context: String?
    /// The sources its cards may quote, best first.
    var sourceIDs: [String]
    /// Passages already known to bear on it.
    var passages: [SituatedPassage]

    init(kind: Kind, text: String, context: String? = nil, sourceIDs: [String], passages: [SituatedPassage] = []) {
        self.kind = kind
        self.text = text
        self.context = context
        self.sourceIDs = sourceIDs
        self.passages = passages
    }
}

struct SituatedPassage: Codable, Equatable, Sendable {
    var sourceID: String
    var text: String
}
