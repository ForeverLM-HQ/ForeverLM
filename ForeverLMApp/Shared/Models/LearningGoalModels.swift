// Learning goal models, moved out of Models.swift.

import Foundation
import UniformTypeIdentifiers

// MARK: - Learning Goals

/// Review/approval lifecycle for a discovered Learning Companion source.
enum LearningGoalItemReviewState: String, Codable {
    case approved   // seed sources, or discovered sources the user accepted
    case pending    // discovered by topic search, awaiting approval
    case rejected   // discovered but dismissed; tombstoned so it is never re-proposed
}

/// How a source entered a Learning Companion goal's pool.
enum LearningGoalItemOrigin: String, Codable {
    case seed       // explicitly pinned by the user at creation/add time
    case discovered // surfaced by topic similarity search
}

/// A shared calendar placement: a source sits on the Schedule once (one planned
/// day, one completion state) and is tagged with any number of Goals and
/// Notebooks, or none. Reviewing it once counts toward every goal it is tagged with.
struct ScheduledSource: Identifiable, Codable, Equatable {
    let id: String
    let sourceID: String
    var plannedAt: Date          // start-of-day + order-seconds (see learningGoalItemPlannedDate)
    var addedAt: Date
    var completedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    var isCompleted: Bool { completedAt != nil }
}

/// Lightweight goal reference for tagging a placement in the UI / MCP output.
struct GoalTag: Identifiable, Codable, Equatable {
    let id: String
    let title: String
}

/// A shared placement together with the goals it's tagged with (for loading the
/// unified Schedule calendar in one pass).
struct ScheduledSourceEntry: Identifiable, Equatable {
    let placement: ScheduledSource
    let goalTags: [GoalTag]
    /// Every goal this placement is tagged with, including companion Notebooks.
    /// `goalTags` is what chips show (Goals, never top-level Notebooks); `goalIDs`
    /// is full membership, used to scope a Notebook/goal's own schedule view.
    var goalIDs: Set<String> = []
    /// True only when the placement was created by learning activity rather
    /// than chosen by the learner or attached to a goal.
    var isAutomatic: Bool = false
    /// Automatic learning history attached to this source-global placement.
    /// Plans remain editable independently; activity is an immutable day record.
    var activityDays: [SourceActivityDay] = []
    var id: String { placement.id }
}

struct LearningGoalItem: Identifiable, Codable, Equatable {
    let id: String
    let goalID: String
    let sourceID: String
    var addedAt: Date
    var completedAt: Date?

    // Learning Companion fields (nil on items with no companion origin).
    var origin: String?       // LearningGoalItemOrigin raw value
    var reviewState: String?  // LearningGoalItemReviewState raw value
    var relevance: Double?    // discovery's rank score, for ordering suggestions; no meaning on its own
    var lastQuizzedAt: Date?  // last time this item appeared in a daily quiz
    var quizCount: Int?       // number of daily quizzes this item has appeared in
    var lastScore: Double?    // most recent quiz score (0..1), drives spaced resurfacing
    var sequence: Double?     // user-defined study order within the Notebook pool; nil = unsequenced (sorts last, by addedAt)

    init(
        id: String,
        goalID: String,
        sourceID: String,
        addedAt: Date,
        completedAt: Date? = nil,
        origin: String? = nil,
        reviewState: String? = nil,
        relevance: Double? = nil,
        lastQuizzedAt: Date? = nil,
        quizCount: Int? = nil,
        lastScore: Double? = nil,
        sequence: Double? = nil
    ) {
        self.id = id
        self.goalID = goalID
        self.sourceID = sourceID
        self.addedAt = addedAt
        self.completedAt = completedAt
        self.origin = origin
        self.reviewState = reviewState
        self.relevance = relevance
        self.lastQuizzedAt = lastQuizzedAt
        self.quizCount = quizCount
        self.lastScore = lastScore
        self.sequence = sequence
    }

    var isCompleted: Bool { completedAt != nil }

    /// Companion items are eligible for the daily blend only once approved.
    /// Items with no review state are treated as approved.
    var isApproved: Bool {
        (reviewState ?? LearningGoalItemReviewState.approved.rawValue) == LearningGoalItemReviewState.approved.rawValue
    }

    var isPendingApproval: Bool {
        reviewState == LearningGoalItemReviewState.pending.rawValue
    }

    enum UnderstandingState: String, Codable, CaseIterable {
        case toRead = "to-read"
        case reading = "reading"
        case understood = "understood"
    }

    /// Derived from retention fields — matches MCP `list_notebook_sources` / `get_notebook_context`.
    var derivedUnderstandingState: UnderstandingState {
        if isCompleted { return .understood }
        if let score = lastScore, score >= 0.7 { return .understood }
        if (quizCount ?? 0) > 0 || lastQuizzedAt != nil { return .reading }
        return .toRead
    }
}

/// A durable "what the learner doesn't understand yet" entry that carries
/// across daily quizzes for a Learning Companion goal.
struct LearningGoalGap: Identifiable, Codable, Equatable {
    let id: String
    let goalID: String
    var summary: String
    var sourceID: String?
    var status: String          // open | improving | resolved
    var severity: Double?       // 0..1, how central to the goal
    var firstSeenAt: Date
    var lastSeenAt: Date
    var resolvedAt: Date?
    var sessionID: String?      // session that surfaced/updated it

    var isOpen: Bool { status != "resolved" }
}

/// Lifecycle state of a Notebook or Goal, stored in `learning_goals.status`.
/// `active` is the column default, so it is also the
/// parse fallback for any unrecognized value.
enum LearningGoalStatus: String, Codable, CaseIterable, Sendable {
    case active
    case done
    case archived

    /// Tolerant parse for the stored column: nil, empty, or anything
    /// unrecognized reads as `.active`.
    static func parse(_ raw: String?) -> LearningGoalStatus {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let parsed = LearningGoalStatus(rawValue: raw) else { return .active }
        return parsed
    }
}

struct LearningGoalRecord: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var startAt: Date
    var endAt: Date
    var createdAt: Date
    var updatedAt: Date
    var status: String
    var items: [LearningGoalItem]

    // Learning Companion fields (nil on Schedules with no companion kind).
    var kind: String?            // "companion" for proactive daily-quiz goals
    var description: String?     // a Notebook's standing Instructions (guidance for chat); a Goal's plain summary
    /// A Notebook's short description: one or two lines shown on its gallery
    /// card and in the Notebook overview. Display copy for the learner, unlike
    /// `description`, which is guidance for the model. nil when never written.
    var summary: String?
    var topic: String?           // natural-language topic for discovery
    var discoveryEnabled: Bool?  // auto-discover related sources by topic each day
    var dailyTarget: Int?        // items per daily quiz
    var lastQuizDate: String?    // YYYY-MM-DD of the last served quiz
    var lastDiscoveryAt: Date?   // last incremental discovery pass
    var gaps: [LearningGoalGap]? // evolving understanding model
    var notes: String?           // Notebook synthesis notes (markdown)
    var parentNotebookID: String? // when set, this companion goal is a timebound Goal that lives inside the named Notebook
    /// The Notebook's defining research questions, in the learner's priority
    /// order — the questions the Notebook exists to answer, distinct from the
    /// emergent open-question gaps. nil means "never set" (old records and old
    /// devices), which sync must treat as no-opinion rather than clearing; an
    /// explicitly emptied list is `[]`.
    var researchQuestions: [String]?
    /// Directional references to other top-level Notebooks whose sources and
    /// synthesis are available as context here. nil means an older payload has
    /// no opinion; [] is an explicit absence of links.
    var relatedNotebookIDs: [String]?
    /// The GitHub repository this Notebook is about, as canonical `owner/repo`.
    /// Only the name is stored: a chat in the Notebook reads the repository
    /// live through the read-only GitHub tools, nothing from GitHub lands in
    /// the library. Tri-state like `researchQuestions`: nil is "never set" (an
    /// old record or an older device with no opinion, which sync keeps local),
    /// `""` is an explicit unlink that travels and wins, and read through
    /// `linkedRepository` both read as no repository.
    var repository: String?
    /// The artifact a Goal is for — the Doc, Site or animation that *is* the
    /// deliverable ("Make a site of the rare mitochondrial diseases" and the
    /// site itself), by record id. One link: a Goal is one outcome. Tri-state
    /// like `repository`: nil is "never set" (an old record or an older device
    /// with no opinion, which sync keeps local), `""` is an explicit unlink
    /// that travels and wins, and both read as no artifact through
    /// `linkedArtifactID`. Only the id is stored; the row resolves the record
    /// from the loaded library, and a record that is gone reads as unlinked.
    var artifactID: String?
    /// Where the learner put the Goal in the Goals tab (product owner, 2026-09-20:
    /// "allow me to reshuffle these"). nil is a Goal never placed by hand,
    /// which reads by deadline after every placed one (`listOrder`); a
    /// placement is the row's index in the order the learner last made.
    /// Rides the learningGoal payload as a new Codable key an older client
    /// decodes to nil, which the sync upsert reads as no opinion, so a
    /// rearrangement made here survives a save from a build that never
    /// heard of it. Never reset by a status change: a Goal reopened comes
    /// back where it was.
    var sortOrder: Int?
    /// The team whose library this Notebook belongs to; nil for My Library.
    /// Decoded as optional so records from older devices keep decoding.
    var teamID: String?

    init(
        id: String,
        title: String,
        startAt: Date,
        endAt: Date,
        createdAt: Date,
        updatedAt: Date,
        status: String,
        items: [LearningGoalItem],
        kind: String? = nil,
        description: String? = nil,
        summary: String? = nil,
        topic: String? = nil,
        discoveryEnabled: Bool? = nil,
        dailyTarget: Int? = nil,
        lastQuizDate: String? = nil,
        lastDiscoveryAt: Date? = nil,
        gaps: [LearningGoalGap]? = nil,
        notes: String? = nil,
        parentNotebookID: String? = nil,
        researchQuestions: [String]? = nil,
        relatedNotebookIDs: [String]? = nil,
        repository: String? = nil,
        teamID: String? = nil,
        artifactID: String? = nil,
        sortOrder: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.startAt = startAt
        self.endAt = endAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
        self.items = items
        self.kind = kind
        self.description = description
        self.summary = summary
        self.topic = topic
        self.discoveryEnabled = discoveryEnabled
        self.dailyTarget = dailyTarget
        self.lastQuizDate = lastQuizDate
        self.lastDiscoveryAt = lastDiscoveryAt
        self.gaps = gaps
        self.notes = notes
        self.parentNotebookID = parentNotebookID
        self.researchQuestions = researchQuestions
        self.relatedNotebookIDs = relatedNotebookIDs
        self.repository = repository
        self.teamID = teamID
        self.artifactID = artifactID
        self.sortOrder = sortOrder
    }

    /// The order the Goals tab, the Planner's Goal picker and `list_goals`
    /// share: the Goals the learner placed first, in the order they were
    /// placed, then the rest by deadline (nearest first) and, within a day,
    /// by when they were set. A placed Goal keeps its place whatever its
    /// deadline does, so an overdue Goal the learner put third stays third;
    /// a Goal never placed reads where the deadline puts it, below the
    /// placed ones. `KnowledgeStore.reorderLearningGoals` writes the
    /// placements this reads.
    static func listOrder(_ lhs: LearningGoalRecord, _ rhs: LearningGoalRecord) -> Bool {
        switch (lhs.sortOrder, rhs.sortOrder) {
        case let (left?, right?) where left != right:
            return left < right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            if lhs.endAt != rhs.endAt { return lhs.endAt < rhs.endAt }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id < rhs.id
        }
    }

    static let companionKind = LearningGoalShape.companionKind
    /// Longest stored Notebook summary; the Portable rule every client shares.
    static let summaryMaxLength = NotebookSummary.maxLength

    /// Stored `end_at` at or beyond this threshold means the notebook has no
    /// real deadline. Both live in Portable (`LearningGoalShape`), which the
    /// phone reads its payloads through too.
    static let openEndedEndAt = Date(timeIntervalSinceReferenceDate: LearningGoalShape.openEndedEndAtReferenceSeconds) // 2100-01-01 UTC
    static let openEndedThreshold = Date(timeIntervalSinceReferenceDate: LearningGoalShape.openEndedThresholdReferenceSeconds)

    var isCompanion: Bool { kind == LearningGoalRecord.companionKind }

    /// User-written description when set.
    var displayDescription: String? {
        guard let raw = description?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    /// The Notebook's short description when set — the card and overview copy.
    var displaySummary: String? {
        guard let raw = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    /// The linked GitHub repository as `owner/repo` when one is set; nil for
    /// both never-set and explicitly unlinked (`""`).
    var linkedRepository: String? {
        Self.normalizedRepository(repository)
    }

    /// The id of the artifact this Goal is for, or nil: both the never-set
    /// NULL and the explicit-unlink `""` read as no artifact.
    var linkedArtifactID: String? {
        guard let trimmed = artifactID?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// The canonical `owner/repo` for what a learner typed or pasted, or nil
    /// when it does not name a GitHub repository. The rule lives in Portable
    /// (`GitHubRepositoryName`) so the phone reads the identical form.
    static func normalizedRepository(_ raw: String?) -> String? {
        GitHubRepositoryName.normalized(raw)
    }

    var isOpenEnded: Bool {
        LearningGoalShape.isOpenEnded(kind: kind, endAtReferenceSeconds: endAt.timeIntervalSinceReferenceDate)
    }

    /// Whether a parent Notebook is named at all. The discriminator between a
    /// Notebook and a Goal is the *deadline*, not this: a Goal may name a
    /// Notebook or stand on its own.
    var hasParentNotebook: Bool {
        LearningGoalShape.namesParentNotebook(parentNotebookID)
    }

    /// A top-level Notebook: an open-ended companion record with no parent.
    /// Notebooks own a source pool and have no timeline of their own.
    ///
    /// Open-endedness is what says "Notebook", because a Goal without a Notebook
    /// is an ordinary thing to want ("I want to understand Zara's thesis work"
    /// names no source pool) and parentlessness alone can no longer tell the
    /// two apart. Schema 120 promoted every parentless companion record
    /// created before Goals shipped (2026-09-19) to `openEndedEndAt`, so a dated parentless record is a Goal the learner
    /// set and never a Notebook from an older build — including one that an
    /// older build received over sync and has yet to migrate.
    var isNotebook: Bool {
        LearningGoalShape.isNotebook(
            kind: kind,
            parentNotebookID: parentNotebookID,
            endAtReferenceSeconds: endAt.timeIntervalSinceReferenceDate
        )
    }

    /// A timebound Goal: a companion record carrying a real deadline. It may
    /// name a Notebook whose sources it draws on (`parentNotebookID`), or stand
    /// on its own. Goals carry the deadline and the day schedule.
    var isGoal: Bool {
        LearningGoalShape.isGoal(kind: kind, endAtReferenceSeconds: endAt.timeIntervalSinceReferenceDate)
    }

    /// A Goal that names no Notebook. The Goals tab lists these beside the
    /// nested ones; only the tag on the row differs.
    var isStandaloneGoal: Bool {
        isGoal && !hasParentNotebook
    }

    /// A timebound Goal nested inside a Notebook, for the places that mean the
    /// nesting itself — a Notebook's own list of Goals, and the source pool a
    /// nested Goal inherits.
    var isNotebookGoal: Bool {
        isGoal && hasParentNotebook
    }

    /// Lifecycle state. Completion is explicit state, never inferred from the
    /// deadline: an outcome Goal whose deadline passed is *overdue*, not done.
    var lifecycleStatus: LearningGoalStatus { LearningGoalStatus.parse(status) }

    var isDone: Bool { lifecycleStatus == .done }

    var isArchived: Bool { lifecycleStatus == .archived }

    /// Past its deadline with the work still open. Open-ended Notebooks (which
    /// carry the 2100 sentinel) can never be overdue.
    func isOverdue(asOf now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard isCompanion, !isOpenEnded, lifecycleStatus == .active else { return false }
        return calendar.startOfDay(for: endAt) < calendar.startOfDay(for: now)
    }

    /// Days until the deadline; negative once overdue. Nil for open-ended Notebooks.
    func daysRemaining(asOf now: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard isCompanion, !isOpenEnded else { return nil }
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: endAt)
        ).day
    }

    var completedCount: Int {
        items.filter(\.isCompleted).count
    }

    var totalCount: Int {
        items.count
    }

    var progress: Double {
        guard totalCount > 0 else { return 0 }
        return Double(completedCount) / Double(totalCount)
    }

    var isComplete: Bool {
        totalCount > 0 && completedCount == totalCount
    }

    /// Source IDs in this Notebook's pool that are approved (seeds + approved discoveries),
    /// in pool order. This is the Notebook's MCP source context. Pending/rejected
    /// discovered suggestions are excluded.
    var approvedSourceIDs: [String] {
        var seen = Set<String>()
        return items
            .filter { $0.isApproved }
            .map(\.sourceID)
            .filter { seen.insert($0).inserted }
    }
}

/// One child notebook produced by splitting a companion goal.
struct CompanionGoalSplitSpec: Equatable, Sendable {
    let title: String
    let topic: String?
    let sourceIDs: [String]
    let gapIDs: [String]
}

/// Outcome of splitting a companion goal into child notebooks. `parentGoalID`
/// is nil when the split removed the emptied parent; `heirGoalID` is then the
/// child that took everything else the parent held (its chats, Goals, tasks,
/// Docs, files and the rest), the one that took the most sources.
struct CompanionGoalSplitResult: Equatable, Sendable {
    let parentGoalID: String?
    let childGoalIDs: [String]
    var heirGoalID: String? = nil
}

/// Outcome of merging Notebooks into one survivor. The counts name what moved
/// so the learner can be told; `filesMoved` is filled in by the caller that
/// owns the workspace folders, since the store only indexes them.
struct CompanionGoalMergeResult: Equatable, Sendable {
    let survivorGoalID: String
    let mergedGoalIDs: [String]
    let sourcesAdded: Int
    let gapsAdded: Int
    var chatsMoved: Int = 0
    var childGoalsMoved: Int = 0
    var tasksMoved: Int = 0
    var docsMoved: Int = 0
    var filesMoved: Int = 0
}

/// Lightweight row describing a completed goal-linked review, for the in-app
/// Learning Companion goal dashboard (history list under the goal hero).
struct CompanionSessionSummary: Identifiable, Codable, Equatable {
    let id: String
    let endedAt: Date
    let overallScore: Double?
    let summary: String?
}
