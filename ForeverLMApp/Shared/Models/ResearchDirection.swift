import Foundation

/// A research direction ForeverLM proposed toward something the learner is
/// after — a Goal, a Notebook or an Idea (product owner, 2026-09-28: "a user
/// identifies a goal, and it helps to do research, and come up with
/// potentially interesting directions"; his example, "find potentially
/// interesting methods to target rare mitochondrial diseases").
///
/// A Direction is a proposal, not a finding: one sentence naming the approach
/// and whom or what it is for, why it is worth a look now, the evidence it
/// rests on (papers and pages the search actually opened), the strongest case
/// against it, and the cheapest step that would tell whether it holds. It
/// stays a proposal until the learner answers it — **Pursue** or **Set
/// aside**, with their reason — and those answers are what the next search
/// reads first, so the proposals bend toward what this learner wants rather
/// than toward what sounds plausible. See docs/directions-design.md.
///
/// Not an Idea (`IdeaRecord`): an Idea is what the learner thought and
/// nothing about it is generated; a Direction is what ForeverLM proposed.
struct ResearchDirection: Identifiable, Codable, Equatable, Sendable {
    let id: String
    /// What the Direction is toward. Fixed at creation: a proposal made for
    /// one Goal is not moved to another.
    let homeKind: DirectionHomeKind
    let homeID: String
    /// The direction in one sentence: the mechanism or approach, and the
    /// population, system or problem it is aimed at.
    var title: String
    /// Why it is worth a look now — what makes it more than plausible.
    var rationale: String
    /// Which way of looking produced it.
    var angle: DirectionAngle
    /// What it rests on, in the order the search gave them.
    var evidence: [DirectionEvidence]
    /// The strongest objection or the prior art that cuts against it.
    var objection: String?
    /// The cheapest experiment, analysis or reading that would tell whether
    /// it holds.
    var nextStep: String?
    var status: DirectionStatus
    /// The learner's words when they answered it: why they pursued it or set
    /// it aside. The next search reads these as its calibration.
    var verdictReason: String?
    /// The chat whose search proposed it, when there was one.
    var chatSessionID: String?
    let createdAt: Date
    var updatedAt: Date
    /// When the learner last answered it; nil while it is a proposal.
    var decidedAt: Date?

    init(
        id: String = UUID().uuidString,
        homeKind: DirectionHomeKind,
        homeID: String,
        title: String,
        rationale: String,
        angle: DirectionAngle = .other,
        evidence: [DirectionEvidence] = [],
        objection: String? = nil,
        nextStep: String? = nil,
        status: DirectionStatus = .proposed,
        verdictReason: String? = nil,
        chatSessionID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        decidedAt: Date? = nil
    ) {
        self.id = id
        self.homeKind = homeKind
        self.homeID = homeID
        self.title = title
        self.rationale = rationale
        self.angle = angle
        self.evidence = evidence
        self.objection = objection
        self.nextStep = nextStep
        self.status = status
        self.verdictReason = verdictReason
        self.chatSessionID = chatSessionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.decidedAt = decidedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, homeKind, homeID, title, rationale, angle, evidence, objection
        case nextStep, status, verdictReason, chatSessionID, createdAt, updatedAt, decidedAt
    }

    /// Tolerant of a record from a newer build: an unknown angle reads as
    /// other and an unknown status as proposed, so a value this build does
    /// not know never fails the whole record. An unknown home kind does fail
    /// it — a Direction whose home cannot be named has nowhere to be shown.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let rawHome = try container.decode(String.self, forKey: .homeKind)
        guard let home = DirectionHomeKind(rawValue: rawHome) else {
            throw DecodingError.dataCorruptedError(
                forKey: .homeKind,
                in: container,
                debugDescription: "Unknown direction home kind \(rawHome)"
            )
        }
        homeKind = home
        homeID = try container.decode(String.self, forKey: .homeID)
        title = try container.decode(String.self, forKey: .title)
        rationale = try container.decodeIfPresent(String.self, forKey: .rationale) ?? ""
        angle = DirectionAngle(rawValue: try container.decodeIfPresent(String.self, forKey: .angle) ?? "") ?? .other
        evidence = try container.decodeIfPresent([DirectionEvidence].self, forKey: .evidence) ?? []
        objection = try container.decodeIfPresent(String.self, forKey: .objection)
        nextStep = try container.decodeIfPresent(String.self, forKey: .nextStep)
        status = DirectionStatus(rawValue: try container.decodeIfPresent(String.self, forKey: .status) ?? "") ?? .proposed
        verdictReason = try container.decodeIfPresent(String.self, forKey: .verdictReason)
        chatSessionID = try container.decodeIfPresent(String.self, forKey: .chatSessionID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        decidedAt = try container.decodeIfPresent(Date.self, forKey: .decidedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(homeKind.rawValue, forKey: .homeKind)
        try container.encode(homeID, forKey: .homeID)
        try container.encode(title, forKey: .title)
        try container.encode(rationale, forKey: .rationale)
        try container.encode(angle.rawValue, forKey: .angle)
        try container.encode(evidence, forKey: .evidence)
        try container.encodeIfPresent(objection, forKey: .objection)
        try container.encodeIfPresent(nextStep, forKey: .nextStep)
        try container.encode(status.rawValue, forKey: .status)
        try container.encodeIfPresent(verdictReason, forKey: .verdictReason)
        try container.encodeIfPresent(chatSessionID, forKey: .chatSessionID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(decidedAt, forKey: .decidedAt)
    }

    var isProposed: Bool { status == .proposed }
    var isPursued: Bool { status == .pursued }
    var isSetAside: Bool { status == .setAside }

    /// Pursued first (what the learner chose to follow), then the proposals
    /// still waiting, then what was set aside; newest first within each.
    static func listOrder(_ lhs: ResearchDirection, _ rhs: ResearchDirection) -> Bool {
        if lhs.status.listRank != rhs.status.listRank { return lhs.status.listRank < rhs.status.listRank }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id < rhs.id
    }

    // MARK: Limits and normalization

    static let titleLimit = 300
    static let textLimit = 4_000
    static let reasonLimit = 1_000
    static let evidenceLimit = 8
    /// The most one `propose_directions` call may save. A search that found
    /// more has not chosen yet.
    static let proposalBatchLimit = 10

    /// One line, trimmed, capped — the way a Direction's sentence is stored.
    static func normalizedTitle(_ raw: String) -> String {
        let collapsed = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(collapsed.prefix(titleLimit))
    }

    /// Trimmed prose, capped; nil when nothing is left.
    static func normalizedText(_ raw: String?, limit: Int = textLimit) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(limit))
    }

    /// The key two proposals for one home are the same Direction under:
    /// the sentence folded for case, width and diacritics, with punctuation
    /// and spacing ignored. Deterministic on purpose — which record a
    /// proposal is must never depend on a model's judgement.
    static func duplicateKey(_ title: String) -> String {
        let folded = normalizedTitle(title)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return folded.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}

/// What a Direction can be toward. Goals and Notebooks are both
/// `learning_goals` rows (a deadline is what makes one a Goal); an Idea is an
/// `ideas` row.
enum DirectionHomeKind: String, Codable, CaseIterable, Sendable {
    case goal
    case notebook
    case idea

    var noun: String { rawValue }

    /// Reads the kind an older build saved as 'project' (a notebook was called a project
    /// until 2026-10-04) as `.notebook`; writes only the current word.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let kind = Self(rawValue: raw == "project" ? Self.notebook.rawValue : raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown DirectionHomeKind \(raw)"))
        }
        self = kind
    }
}

/// The way of looking that produced a Direction. A search that works each
/// angle in turn proposes things of different kinds, rather than five
/// rewordings of the obvious one.
enum DirectionAngle: String, Codable, CaseIterable, Sendable {
    /// A mechanism or approach that plausibly fits and that nobody is
    /// pursuing for this problem.
    case gap
    /// Something that worked on a neighbouring problem, and why it might
    /// carry over.
    case transfer
    /// An approach that failed or stalled, and what has changed since that
    /// could rescue it — a better-defined population, a new readout, a new
    /// tool.
    case revival
    /// A recent method, tool or finding that makes an impractical route
    /// feasible.
    case enabling
    /// Two things in the learner's own library, Ideas or chats that bear on
    /// each other and that nobody has put together.
    case connection
    /// An assumption the field makes that the evidence does not fully
    /// support.
    case contrarian
    case other

    /// The chip's word.
    var label: String {
        switch self {
        case .gap: return "Gap"
        case .transfer: return "Transfer"
        case .revival: return "Revival"
        case .enabling: return "New tool"
        case .connection: return "Your library"
        case .contrarian: return "Contrarian"
        case .other: return "Direction"
        }
    }

    var symbolName: String {
        switch self {
        case .gap: return "square.dashed"
        case .transfer: return "arrow.left.arrow.right"
        case .revival: return "arrow.counterclockwise"
        case .enabling: return "wrench.and.screwdriver"
        case .connection: return "point.3.connected.trianglepath.dotted"
        case .contrarian: return "exclamationmark.bubble"
        case .other: return "signpost.right"
        }
    }

    /// One line on what the angle means, for the search's steps and the
    /// tool contract.
    var meaning: String {
        switch self {
        case .gap: return "a mechanism or approach that plausibly fits and that nobody is pursuing for this problem"
        case .transfer: return "something that worked on a neighbouring problem, and why it might carry over"
        case .revival: return "an approach that failed or stalled, and what has changed since that could rescue it (a better-defined population, a new readout, a new tool)"
        case .enabling: return "a recent method, tool or finding that makes a previously impractical route feasible"
        case .connection: return "two things in the learner's own library, Ideas or chats that bear on each other and that nobody has put together"
        case .contrarian: return "an assumption the field makes that the evidence does not fully support"
        case .other: return "anything that fits none of the above"
        }
    }
}

enum DirectionStatus: String, Codable, CaseIterable, Sendable {
    /// Proposed by a search, not answered yet.
    case proposed
    /// The learner chose to follow it.
    case pursued
    /// The learner set it aside, usually with a reason. Kept, so the next
    /// search does not propose it again and knows why.
    case setAside = "set_aside"

    var listRank: Int {
        switch self {
        case .pursued: return 0
        case .proposed: return 1
        case .setAside: return 2
        }
    }

    var label: String {
        switch self {
        case .proposed: return "Proposed"
        case .pursued: return "Pursuing"
        case .setAside: return "Set aside"
        }
    }
}

/// One thing a Direction rests on: a paper or page the search opened, and
/// what it shows for this Direction. A citation is text for the learner; the
/// DOI or address is what identifies it. Whether the library holds it is
/// looked up by that DOI or address whenever the Direction is read, never
/// stored and never taken from a model, so a paper added later reads as in
/// the library without the record being written again.
struct DirectionEvidence: Codable, Equatable, Hashable, Sendable {
    /// "Jain et al., Science 2016".
    var citation: String
    var title: String?
    var url: String?
    var doi: String?
    /// What it shows for this Direction, in a sentence.
    var finding: String

    init(citation: String, title: String? = nil, url: String? = nil, doi: String? = nil, finding: String) {
        self.citation = citation
        self.title = title
        self.url = url
        self.doi = doi
        self.finding = finding
    }

    /// The address to open or import: the page itself, or the DOI's
    /// resolver when only a DOI was given.
    var openURL: URL? {
        if let url, let parsed = URL(string: url), parsed.scheme?.hasPrefix("http") == true { return parsed }
        if let doi = Self.normalizedDOI(doi) { return URL(string: "https://doi.org/\(doi)") }
        return nil
    }

    /// A DOI as `10.x/y`: resolver prefixes and a `doi:` label stripped,
    /// lowercased. nil when what is left is not a DOI.
    static func normalizedDOI(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        for prefix in ["https://doi.org/", "http://doi.org/", "https://dx.doi.org/", "http://dx.doi.org/", "doi:", "DOI:"] {
            if value.lowercased().hasPrefix(prefix.lowercased()) {
                value = String(value.dropFirst(prefix.count))
                break
            }
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.hasPrefix("10."), value.contains("/") else { return nil }
        return value
    }
}

/// The `ResearchDirection` CloudKit record: one Direction whole, evidence
/// included. Schema gate: create `ResearchDirection` with `payload` and
/// `userModificationDate` in Development, then deploy it to Production
/// before shipping the build that writes it.
struct CloudKitResearchDirectionPayload: Codable, Sendable {
    let direction: ResearchDirection

    init(direction: ResearchDirection) {
        self.direction = direction
    }
}
