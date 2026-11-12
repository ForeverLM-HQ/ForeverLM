import Foundation

/// One thing a person who understood a source could say back.
///
/// Ideas are the unit of memory (docs/memory-design.md). They are extracted
/// once per source when it has been substantially consumed, synced because
/// extraction is billed and both devices must agree on the ids, and regenerated
/// only when the source's content hash changes — the old generation is then
/// retired rather than deleted, so exchanges and targets keep their references.
///
/// Identity is deterministic and app-owned: `Self.id(sourceID:contentHash:index:)`.
/// A model asserts an idea id in a grade; it never chooses one.
struct SourceIdea: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let sourceID: String
    /// One sentence, in the register a learner would use to say it back.
    var statement: String
    /// What a good recall contains: the two or three things the grader checks.
    var recallNote: String
    /// Where in the source the idea lives. Quotes, not offsets, so an anchor
    /// survives a re-extraction of the same text and reads on every surface.
    var anchors: [SourceIdeaAnchor]
    /// Anchored to a passage the learner highlighted or wrote a note about.
    /// Wanted ideas lead the contour grading and the probes.
    var wanted: Bool
    /// The chat an idea was born in, when it came from a conversation rather
    /// than from the source text.
    var originSessionID: String?
    /// SHA-256 of the source text the idea was extracted from.
    let contentHash: String
    var status: SourceIdeaStatus
    var sortIndex: Int
    let createdAt: Date
    var updatedAt: Date

    init(
        id: String,
        sourceID: String,
        statement: String,
        recallNote: String,
        anchors: [SourceIdeaAnchor] = [],
        wanted: Bool = false,
        originSessionID: String? = nil,
        contentHash: String,
        status: SourceIdeaStatus = .active,
        sortIndex: Int,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sourceID = sourceID
        self.statement = statement
        self.recallNote = recallNote
        self.anchors = anchors
        self.wanted = wanted
        self.originSessionID = originSessionID
        self.contentHash = contentHash
        self.status = status
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// `<sourceID>::idea::<hash prefix>::<index>`. The hash prefix keeps two
    /// generations of the same source apart; the index keeps the id readable in
    /// a grade payload and a transcript.
    static func id(sourceID: String, contentHash: String, index: Int) -> String {
        "\(sourceID)::idea::\(contentHash.prefix(12))::\(index)"
    }

    /// The source an idea id names, without a lookup. nil for a foreign id.
    static func sourceID(fromIdeaID ideaID: String) -> String? {
        guard let range = ideaID.range(of: "::idea::") else { return nil }
        let prefix = ideaID[..<range.lowerBound]
        return prefix.isEmpty ? nil : String(prefix)
    }

    /// How many ideas a source may carry. The extraction prompt asks for a
    /// number by length; this is the ceiling the store enforces.
    static let maximumPerSource = 12
}

enum SourceIdeaStatus: String, Codable, Sendable {
    case active
    case retired
}

struct SourceIdeaAnchor: Codable, Equatable, Sendable {
    /// A short exact passage from the source.
    let quote: String
    /// The learner's highlight the passage overlaps, when it does.
    let highlightID: String?

    init(quote: String, highlightID: String? = nil) {
        self.quote = quote
        self.highlightID = highlightID
    }
}

/// How much of a review a source gets by default. Never a form: the tutor sets
/// it when the learner says so ("keep podcasts quick") or infers it from three
/// consecutive Next or Go deeper choices, and announces the inference once.
enum MemoryReviewDepth: String, Codable, CaseIterable, Sendable {
    /// The contour only.
    case quick
    /// The contour, then probes while the budget allows.
    case standard
    /// The contour, then the planner's full move list.
    case deep

    var displayName: String {
        switch self {
        case .quick: return "Quick"
        case .standard: return "Standard"
        case .deep: return "Deep"
        }
    }

    /// What a source gets when neither it nor its type has a chosen depth.
    static let fallback: MemoryReviewDepth = .standard

    /// Per-type defaults live in synced preferences, one key per source type,
    /// under this prefix (see `SyncedPreferenceKeys.syncedPrefixes`).
    static let typePreferenceKeyPrefix = Prefs.Families.reviewDepthByType.prefix
    static func typePreferenceKey(sourceType: String) -> String {
        typePreferenceKeyPrefix + sourceType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The depth a source is reviewed at: its own, else its type's chosen
    /// default, else the fallback. Reading the type default is the client's
    /// business (the Mac's preference store, the phone's synced rows), so it
    /// arrives here as a value; see `MemoryReview+MacRecords.swift`.
    static func effective(sourceDepth: MemoryReviewDepth?, typeDefault: MemoryReviewDepth?) -> MemoryReviewDepth {
        sourceDepth ?? typeDefault ?? fallback
    }

    /// How the tutor should read this depth when the learner says nothing.
    var tutorInstruction: String {
        switch self {
        case .quick:
            return "quick: the contour only — in the graded reply, ask whether to move on or go deeper, and wait"
        case .standard:
            return "standard: the contour, then one or two probes while the budget allows — after the last probe's reply, ask whether to move on or stay, and wait"
        case .deep:
            return "deep: the contour, then the planner's full move list for this source — after the last move, ask whether to move on, and wait"
        }
    }
}

/// What a chat is for. Stored on `review_sessions.kind` from schema 89; rows
/// older than that are read through the session id, which `MemoryReviewSession`
/// already prefixes.
enum ReviewSessionKind: String, Codable, Sendable {
    case chat
    case review
    case memory
}

/// The grader's verdict on one idea after a free recall.
struct MemoryIdeaCoverage: Codable, Equatable, Sendable {
    enum Status: String, Codable, CaseIterable, Sendable {
        case produced
        case partial
        case missing
    }

    let ideaID: String
    let status: Status

    private enum CodingKeys: String, CodingKey {
        case ideaID = "idea_id"
        case status
    }

    init(ideaID: String, status: Status) {
        self.ideaID = ideaID
        self.status = status
    }

    /// The fraction of ideas produced unaided, which is what moves a source's
    /// rung. Partial counts half: the shape came back without the substance.
    static func producedFraction(_ coverage: [MemoryIdeaCoverage]) -> Double {
        guard !coverage.isEmpty else { return 0 }
        let total = coverage.reduce(0.0) { sum, entry in
            switch entry.status {
            case .produced: return sum + 1
            case .partial: return sum + 0.5
            case .missing: return sum
            }
        }
        return total / Double(coverage.count)
    }

    static func encode(_ coverage: [MemoryIdeaCoverage]) -> String? {
        guard let data = try? JSONEncoder().encode(coverage) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ json: String?) -> [MemoryIdeaCoverage] {
        guard let json, let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([MemoryIdeaCoverage].self, from: data) else {
            return []
        }
        return decoded
    }
}

extension MemoryIdeaCoverage {
    /// A grade's entries grouped by the source each idea belongs to, sources in
    /// the order their first idea appears. A topic grade spans several sources;
    /// a contour grade is one group. An idea id with no source prefix is dropped.
    static func bySource(_ coverage: [MemoryIdeaCoverage]) -> [(sourceID: String, coverage: [MemoryIdeaCoverage])] {
        var order: [String] = []
        var groups: [String: [MemoryIdeaCoverage]] = [:]
        for entry in coverage {
            guard let sourceID = SourceIdea.sourceID(fromIdeaID: entry.ideaID) else { continue }
            if groups[sourceID] == nil { order.append(sourceID) }
            groups[sourceID, default: []].append(entry)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }
}

/// One saved exchange's grade, as the ladder and the day's ledger read it.
/// Any client's exchange record can supply it.
struct MemoryGradedExchange: Equatable, Sendable {
    let sessionID: String
    let sequenceNumber: Int
    let ideaCoverage: String?
    let questionVerdict: String?
    let answeredAt: Date?

    init(sessionID: String, sequenceNumber: Int, ideaCoverage: String?, questionVerdict: String?, answeredAt: Date?) {
        self.sessionID = sessionID
        self.sequenceNumber = sequenceNumber
        self.ideaCoverage = ideaCoverage
        self.questionVerdict = questionVerdict
        self.answeredAt = answeredAt
    }

    var isAmbiguous: Bool { questionVerdict == MemoryQuestionVerdict.ambiguous.rawValue }
}

/// What the source ladder hears from a day's grades: for each session and
/// source, every idea's *first* grade that day.
///
/// A topic's opening grade covers ideas from several sources at once, and
/// Go deeper grades the ideas that did not come back again, one at a time
/// (docs/memory-design.md, "Review by topic"). If every grade counted, a
/// correct answer to a narrow probe would score a whole source (contour
/// re-grades did exactly that). So an idea's first grade
/// of the day is the evidence, a later grade of it moves nothing, and two
/// topics that each cue some of a paper's ideas make one outcome for it.
/// An idea whose first grade came under an ambiguous question contributes
/// nothing; a source left with nothing contributes a nil fraction, which the
/// ladder skips, as an ambiguous contour always did.
enum MemoryLadderEvidence {

    struct Outcome: Equatable, Sendable {
        let sourceID: String
        let sessionID: String
        /// When the source's first idea was graded that session.
        let gradedAt: Date?
        let producedFraction: Double?
    }

    static func outcomes(_ exchanges: [MemoryGradedExchange]) -> [Outcome] {
        struct Key: Hashable { let session: String; let source: String }
        let ordered = exchanges.sorted {
            let a = $0.answeredAt ?? .distantPast, b = $1.answeredAt ?? .distantPast
            if a != b { return a < b }
            if $0.sessionID != $1.sessionID { return $0.sessionID < $1.sessionID }
            return $0.sequenceNumber < $1.sequenceNumber
        }
        var keys: [Key] = []
        var firstAt: [Key: Date?] = [:]
        var seen: [Key: Set<String>] = [:]
        var counted: [Key: [MemoryIdeaCoverage]] = [:]
        for exchange in ordered {
            let coverage = MemoryIdeaCoverage.decode(exchange.ideaCoverage)
            for group in MemoryIdeaCoverage.bySource(coverage) {
                let key = Key(session: exchange.sessionID, source: group.sourceID)
                if firstAt[key] == nil {
                    keys.append(key)
                    firstAt[key] = .some(exchange.answeredAt)
                }
                for entry in group.coverage where seen[key, default: []].insert(entry.ideaID).inserted {
                    if !exchange.isAmbiguous { counted[key, default: []].append(entry) }
                }
            }
        }
        return keys.map { key in
            let entries = counted[key] ?? []
            return Outcome(
                sourceID: key.source,
                sessionID: key.session,
                gradedAt: firstAt[key] ?? nil,
                producedFraction: entries.isEmpty ? nil : MemoryIdeaCoverage.producedFraction(entries)
            )
        }
    }
}

/// Whether a question was fit to be graded. `ambiguous` blames the wording:
/// the answer is graded on the idea, and no rung moves.
enum MemoryQuestionVerdict: String, Codable, Sendable {
    case sound
    case ambiguous
}

/// The cognitive operation a question asked for, recorded on the exchange it
/// was graded on. Encounters with one idea rotate through the first five so
/// the wording never settles; they ask whether the idea comes back.
///
/// The last four are the understanding probes (`MemoryUnderstandingProbe`),
/// asked only once an idea has come back: an answer to one is graded on the
/// probed idea with the probe's kind as its operation, and that grade says how
/// deep the understanding went, never whether the idea came back
/// (`MemoryReviewIdeaState`). They are operations rather than a field of
/// their own so the exchange's existing `operation` column says what was
/// asked, on every device, with no schema change. The planner's move kinds
/// (`CohortMoveKind`) stay the five recall operations: a plan is made before
/// anything has come back, so it has nothing to probe yet.
enum MemoryQuestionOperation: String, Codable, CaseIterable, Sendable {
    case recall
    case explain
    case contrast
    case apply
    case connect
    case principle
    case transfer
    case falsify
    case analogy

    /// Whether this is an understanding probe's operation rather than a
    /// recall's.
    var isUnderstanding: Bool {
        switch self {
        case .recall, .explain, .contrast, .apply, .connect: return false
        case .principle, .transfer, .falsify, .analogy: return true
        }
    }

    /// The operations a recall is graded with: what a contour, a topic's
    /// opening and a probe on what did not come back may name.
    static var recallCases: [MemoryQuestionOperation] { allCases.filter { !$0.isUnderstanding } }
}

/// The learner's steer after a graded answer.
enum MemoryReviewSteer: String, Codable, Sendable {
    case next
    case deeper
}
