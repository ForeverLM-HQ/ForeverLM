import Foundation

/// What a single move in a session asks the learner to do.
///
/// The kinds are ordered roughly by how much they demand: recalling a fact is
/// cheaper than reconciling two sources. A session that is all `recall` is a
/// flashcard deck wearing a costume, which is exactly what this replaces.
enum CohortMoveKind: String, Codable, Equatable, Sendable, CaseIterable {
    /// Produce something specific from memory, unaided.
    case recall
    /// Explain a mechanism in their own words.
    case explain
    /// Distinguish it from a neighbouring idea, or say where two accounts differ.
    case contrast
    /// Use it on a case that was not in the source.
    case apply
    /// Reconcile or relate two sources taken in at different times.
    case connect
}

/// One planned beat of a session.
///
/// `intent` is the point: it says what to push on, not what to say. The tutor
/// composes the actual wording live, so nothing here is ever read aloud and no
/// question is ever stored to be replayed verbatim.
struct CohortMove: Codable, Equatable, Sendable {
    let kind: CohortMoveKind
    let sourceIDs: [String]
    let intent: String

    enum CodingKeys: String, CodingKey {
        case kind
        case sourceIDs = "source_ids"
        case intent
    }
}

/// What a topic is in today's review, which sets how the tutor opens it and
/// how the card labels it (docs/memory-design.md, "Review by topic").
enum MemoryReviewTopicKind: String, Codable, CaseIterable, Sendable {
    /// Taken in recently and not yet reviewed.
    case new
    /// Reviewed before and due again, or a mix of new and due ideas.
    case due
    /// Ideas that did not come back before, on their short ladder.
    case weak
    /// One question across two topics taken in at different times.
    case connection

    var label: String {
        switch self {
        case .new: "New"
        case .due: "Due again"
        case .weak: "Weak spot"
        case .connection: "Connection"
        }
    }

    /// The planner move a topic stands for, so the briefing's move list and
    /// everything that orders sources by it keep working.
    var moveKind: CohortMoveKind {
        switch self {
        case .new: .explain
        case .due, .weak: .recall
        case .connection: .connect
        }
    }
}

/// One topic of today's review: ideas about the same thing, whichever source
/// or chat carried them, asked as one opening question and graded together.
///
/// The model groups ideas and names the topic; code owns the identity. `id`
/// is positional (`topic-1`, `topic-2`, …), assigned after validation, and
/// every idea id has been checked against the ideas the review carries.
struct MemoryReviewTopic: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let kind: MemoryReviewTopicKind
    /// The ideas the topic's opening question cues, in the planner's order.
    let ideaIDs: [String]
    /// A note to the tutor on what to push on; never the question.
    let intent: String

    /// The same key the planner writes, so a plan that was encoded decodes
    /// back as drafts that validate to the same topics.
    enum CodingKeys: String, CodingKey {
        case id
        case title
        case kind
        case ideaIDs = "idea_ids"
        case intent
    }

    static let idPrefix = "topic-"

    static func id(position: Int) -> String { "\(idPrefix)\(position)" }

    static func isTopicID(_ id: String) -> Bool {
        id.hasPrefix(idPrefix) && Int(id.dropFirst(idPrefix.count)) != nil
    }

    /// The sources the topic draws on, in the order its ideas first name them.
    /// An idea id begins with its source's id, so this is a prefix, not a join.
    var sourceIDs: [String] {
        var seen = Set<String>()
        return ideaIDs.compactMap { SourceIdea.sourceID(fromIdeaID: $0) }.filter { seen.insert($0).inserted }
    }

    /// The most ideas one opening question may cue: past this the grade turns
    /// into a checklist and the answer into a list.
    static let maxIdeas = 8
}

/// A topic as the planner writes it, before code has checked it.
struct CohortTopicDraft: Codable, Equatable, Sendable {
    let title: String
    let kind: String?
    let ideaIDs: [String]
    let intent: String?

    enum CodingKeys: String, CodingKey {
        case title
        case kind
        case ideaIDs = "idea_ids"
        case intent
    }
}

/// The planner's output. Held for the length of one session and then discarded.
struct CohortSessionPlan: Codable, Equatable, Sendable {
    /// One line the tutor can open with, naming what today covers.
    let opening: String
    let moves: [CohortMove]
    /// Today's topics, validated and numbered. Empty for a plan made before
    /// topics, or over material that carries no ideas.
    var topics: [MemoryReviewTopic] = []
    /// What the planner returned, before validation. Not kept.
    var topicDrafts: [CohortTopicDraft] = []

    enum CodingKeys: String, CodingKey {
        case opening
        case moves
        case topics
    }

    init(opening: String, moves: [CohortMove], topics: [MemoryReviewTopic] = [], topicDrafts: [CohortTopicDraft] = []) {
        self.opening = opening
        self.moves = moves
        self.topics = topics
        self.topicDrafts = topicDrafts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        opening = try container.decodeIfPresent(String.self, forKey: .opening) ?? ""
        moves = try container.decodeIfPresent([CohortMove].self, forKey: .moves) ?? []
        // The planner writes drafts under `topics`; a validated plan encodes
        // numbered topics there. Either decodes as a draft, and validation
        // numbers them again.
        topicDrafts = (try? container.decodeIfPresent([CohortTopicDraft].self, forKey: .topics)) ?? []
        topics = []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(opening, forKey: .opening)
        try container.encode(moves, forKey: .moves)
        try container.encode(topics, forKey: .topics)
    }

    /// Drops moves that name a source outside the cohort.
    ///
    /// The model is told which sources exist, but a plan that references
    /// something else must not reach the tutor: it would load material the
    /// learner never consumed, or fail to load anything at all. Identity is
    /// deterministic code's business, never the model's.
    func validated(against cohort: LearningCohort) -> CohortSessionPlan {
        let allowed = Set(cohort.sources.map(\.sourceID))
        let kept = moves.filter { move in
            !move.sourceIDs.isEmpty && move.sourceIDs.allSatisfy { allowed.contains($0) }
        }
        return CohortSessionPlan(opening: opening, moves: kept, topics: topics)
    }

    /// Validates the planner's topics against the ideas the review may grade,
    /// then derives the move list from them.
    ///
    /// An idea id the review does not carry is dropped, as is a second use of
    /// an idea already cued by an earlier topic (one idea, one topic, so a
    /// grade can never be claimed twice); a topic left with no ideas goes.
    /// Survivors are numbered in order. When topics survive, the moves are
    /// one per topic, so the briefing's move list, the strip order and the
    /// opening source keep reading as they did; when none do, the plan's own
    /// moves stand, validated against the cohort.
    func validated(against cohort: LearningCohort, briefs: [CohortSourceBrief]) -> CohortSessionPlan {
        let allowedSources = Set(cohort.sources.map(\.sourceID))
        var gradable: Set<String> = []
        for brief in briefs where allowedSources.contains(brief.source.sourceID) {
            for idea in brief.ideas { gradable.insert(idea.id) }
        }
        var claimed = Set<String>()
        var topics: [MemoryReviewTopic] = []
        for draft in topicDrafts {
            let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            var ideaIDs: [String] = []
            for raw in draft.ideaIDs {
                let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard gradable.contains(id), !claimed.contains(id) else { continue }
                claimed.insert(id)
                ideaIDs.append(id)
                if ideaIDs.count == MemoryReviewTopic.maxIdeas { break }
            }
            guard !ideaIDs.isEmpty else { continue }
            let kind = draft.kind
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .flatMap(MemoryReviewTopicKind.init(rawValue:)) ?? .new
            topics.append(MemoryReviewTopic(
                id: MemoryReviewTopic.id(position: topics.count + 1),
                title: title,
                kind: kind,
                ideaIDs: ideaIDs,
                intent: draft.intent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            ))
        }
        guard !topics.isEmpty else { return validated(against: cohort) }
        let moves = topics.compactMap { topic -> CohortMove? in
            let sources = topic.sourceIDs.filter { allowedSources.contains($0) }
            guard !sources.isEmpty else { return nil }
            return CohortMove(kind: topic.kind.moveKind, sourceIDs: sources, intent: "\(topic.title): \(topic.intent)")
        }
        return CohortSessionPlan(opening: opening, moves: moves, topics: topics)
    }

    var connectsAcrossSources: Bool {
        moves.contains { $0.sourceIDs.count > 1 }
    }
}

/// The closer's output: rewritten understanding, plus what stayed open.
struct CohortCloseResult: Codable, Equatable, Sendable {
    struct SourceUpdate: Codable, Equatable, Sendable {
        let sourceID: String
        /// The complete rewritten document, not a patch. Rewriting is what keeps
        /// the file from growing without bound.
        let understandingMarkdown: String
        /// How many threads the closer deliberately left unresolved.
        let openThreadCount: Int
        /// The ids of the source's ideas this conversation actually touched.
        /// A chat is rarely about a whole paper, and a source that enters a
        /// review on the strength of a chat must be asked about what was
        /// said, not about everything the paper contains. Empty means the
        /// chat named the source without engaging any of its ideas.
        var discussedIdeaIDs: [String] = []

        enum CodingKeys: String, CodingKey {
            case sourceID = "source_id"
            case understandingMarkdown = "understanding_markdown"
            case openThreadCount = "open_thread_count"
            case discussedIdeaIDs = "discussed_idea_ids"
        }

        init(
            sourceID: String,
            understandingMarkdown: String,
            openThreadCount: Int,
            discussedIdeaIDs: [String] = []
        ) {
            self.sourceID = sourceID
            self.understandingMarkdown = understandingMarkdown
            self.openThreadCount = openThreadCount
            self.discussedIdeaIDs = discussedIdeaIDs
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sourceID = try container.decode(String.self, forKey: .sourceID)
            understandingMarkdown = try container.decode(String.self, forKey: .understandingMarkdown)
            openThreadCount = try container.decodeIfPresent(Int.self, forKey: .openThreadCount) ?? 0
            discussedIdeaIDs = try container.decodeIfPresent([String].self, forKey: .discussedIdeaIDs) ?? []
        }
    }

    let sessionSummary: String
    let sources: [SourceUpdate]

    enum CodingKeys: String, CodingKey {
        case sessionSummary = "session_summary"
        case sources
    }

    /// Same rule as the plan: an update naming a source the session never
    /// touched is dropped rather than written.
    ///
    /// `ideaIDsBySource` is what each source really carries. A model asserts
    /// idea ids and never chooses them, so an id the source does not have is
    /// dropped — a hallucinated id would otherwise narrow the next review to
    /// nothing, or to an idea that does not exist.
    func validated(
        against touchedSourceIDs: Set<String>,
        ideaIDsBySource: [String: Set<String>] = [:]
    ) -> CohortCloseResult {
        CohortCloseResult(
            sessionSummary: sessionSummary,
            sources: sources
                .filter { touchedSourceIDs.contains($0.sourceID) }
                .map { update in
                    guard let known = ideaIDsBySource[update.sourceID] else { return update }
                    var seen = Set<String>()
                    return SourceUpdate(
                        sourceID: update.sourceID,
                        understandingMarkdown: update.understandingMarkdown,
                        openThreadCount: update.openThreadCount,
                        discussedIdeaIDs: update.discussedIdeaIDs.filter {
                            known.contains($0) && seen.insert($0).inserted
                        }
                    )
                }
        )
    }
}
