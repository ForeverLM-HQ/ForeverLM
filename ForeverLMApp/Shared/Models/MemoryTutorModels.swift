import Foundation

// The durable records (MemoryItem, MemoryAttempt, MemorySchedule and their
// enums) and the pure schedule projection (`MemoryTutorScheduler`) live in
// `Shared/Portable/MemoryTutorRecords.swift`, where the website's WebAssembly
// core compiles them too. This file keeps the rest of the memory tutor's models.

struct DueMemoryItem: Codable, Equatable, Sendable, Identifiable {
    let item: MemoryItem
    let schedule: MemorySchedule
    let daysOverdue: Int

    var id: String { item.id }
}

/// Canonical source text and its full-content hash captured at memory-item intake.
/// The excerpt remains a separate, human-readable anchor; it is never substituted
/// for the source revision hash.
struct MemorySourceSnapshot: Codable, Equatable, Sendable {
    let sourceID: String
    let content: String
    let sourceSHA256: String
}

/// Lightweight result of validating a proposed excerpt against canonical source
/// text on the storage actor. Full source content never crosses to a UI actor.
struct MemorySourceAnchorValidation: Codable, Equatable, Sendable {
    let sourceID: String
    let excerpt: String
    let sourceSHA256: String
    let portableSourceKey: String

    init(
        sourceID: String,
        excerpt: String,
        sourceSHA256: String,
        portableSourceKey: String? = nil
    ) {
        self.sourceID = sourceID
        self.excerpt = excerpt
        self.sourceSHA256 = sourceSHA256
        self.portableSourceKey = portableSourceKey
            ?? MemoryTutorIdentity.portableSourceKey(sourceID: sourceID)
    }
}

// MARK: - Memory Review (daily retention)

/// Per-source retention signal derived from completed review history.
/// Drives the daily "memory training" surface: which previously-studied sources
/// are fading and worth refreshing today. The source is the unit of review — no
/// flashcards, no per-concept state.
struct MemoryReviewStat: Equatable {
    let sourceID: String
    let title: String
    let sourceType: String
    let lastReviewedAt: Date
    /// overall_score of the most recent scored review, if any (nil = ungraded).
    let lastScore: Double?
    /// Distinct completed reviews that covered this source.
    let reviewCount: Int
}

/// The raw per-source consumption columns, read straight off `source_projection`.
/// Kept as a plain value so `SourceConsumption` stays a pure function the unit
/// tests can drive without a database.
struct SourceConsumptionSignals: Equatable {
    /// Explicitly marked read: set when a web article is scrolled to its end, when
    /// the learner picks "Mark as Read", or when a Schedule placement completes
    /// (which is the only path that marks a podcast, video, or paper read).
    var readAt: Date?
    /// Zero-based PDFKit page index of the furthest saved reading position.
    var readingPositionPage: Int?
    /// `ArticleReadingPositionLocator` (web), `EPUBReadingPositionLocator` (book),
    /// or `VideoWatchProgress` (video/recording), JSON-encoded. Transcript readers
    /// persist nothing here.
    var readingPositionLocator: String?
    var dateAdded: Date
    /// Deepest 0...1 fraction of this source reached on any activity day, from
    /// `source_activity_days.max_fraction` (v66+). 0 means unmeasured.
    var maxFraction: Double = 0
    /// When that deepest point was reached. Supplies the consumption timestamp
    /// for sources the learner clearly worked through but never explicitly
    /// finished, which have no `read_at` to date them by.
    var deepestActivityAt: Date?
    /// Time the learner actually spent with the source, summed over its
    /// activity days (`SourceActivityDay.engagedTime`). nil means the caller
    /// has no time evidence at all and depth stands on its own; 0 means time
    /// was measured and none went with the position, which is what a skim to
    /// the end looks like.
    var engagedSeconds: Double? = nil
    /// How long the source takes to go through at a normal pace: the word count
    /// at `SourceConsumption.readingWordsPerMinute`, or the media duration. nil
    /// when the length is unknown, which puts the fixed floor in charge.
    var expectedSeconds: Double? = nil
    /// The most recent day the source was in an ordinary chat the learner wrote
    /// in — attached to it or carried on an exchange. Discussing a source is
    /// consumption whatever the reader recorded.
    var chatDiscussedAt: Date? = nil
    /// Highlights and notes on the source. Nobody marks up what they did not
    /// read, so an annotation lifts the level by one.
    var annotationCount: Int = 0
}

/// How good the evidence is that a source was actually consumed. Ordered, so
/// callers can express a threshold ("substantial or better") instead of
/// restating the rule.
enum SourceConsumptionConfidence: Int, Comparable, Equatable, Sendable {
    /// Nothing beyond the source existing in the library.
    case none = 0
    /// Meaningfully started and abandoned, or still in progress.
    case partial = 1
    /// Most of the way through. Worth reviewing, worth saying so.
    case substantial = 2
    /// Explicitly finished, or played/read to the end.
    case complete = 3

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Did the learner actually *consume* this source, as opposed to merely adding it?
///
/// This is the gate on the never-reviewed bucket in `memory_review`. Auto-ingested
/// libraries fill up with sources the learner never opened — every Safari reading
/// list entry, every podcast episode in a subscribed show — and serving those for
/// review is noise that kills the habit. So mere presence never qualifies; there
/// has to be a positive signal that the material was gone through.
///
/// `read_at` is the learner's own statement and stands on its own. A measured
/// depth is a position, and a position only counts once enough time went with
/// it (docs/memory-design.md, "The engagement ledger"): a paper paged to its
/// end in seconds is not a read paper. A chat the learner wrote in about the
/// source — one whose turns cite it, or that was opened on it alone; never one
/// that merely carried it as Notebook context (`ChatSourceEvidence`) — is
/// consumption whatever the reader saw, and an annotation lifts the level by
/// one. Scroll, page, and playback positions on their own remain resume
/// locators, not evidence.
enum SourceConsumption {
    /// Depth at which an unfinished source counts as substantially consumed.
    static let substantialFraction = 0.6
    /// Depth below which engagement is too shallow to be evidence of anything.
    static let partialFraction = 0.25
    /// Measured depth at or above this is treated as finished. Playback and
    /// scroll positions rarely reach a clean 1.0 — trailing credits, a footer,
    /// a final chunk whose end event never fires.
    static let completeFraction = 0.9

    /// A normal reading pace, for turning a word count into expected time.
    static let readingWordsPerMinute = 250.0
    /// Share of the expected time that has to have gone with a finished
    /// position before it counts as complete.
    static let completeTimeShare = 0.5
    /// Share of the expected time a substantial position needs.
    static let substantialTimeShare = 1.0 / 3.0
    /// The time floor when nothing says how long the source is.
    static let unknownLengthFloorSeconds = 120.0
    /// No floor is ever lower than this, so a fifty-word post still needs a
    /// pause on it rather than a flicker past it.
    static let minimumFloorSeconds = 30.0

    /// Expected seconds to read `wordCount` words; nil when the count is
    /// unknown or empty.
    static func expectedSeconds(wordCount: Int?) -> Double? {
        guard let wordCount, wordCount > 0 else { return nil }
        return Double(wordCount) / readingWordsPerMinute * 60
    }

    /// The engaged time a depth-derived `level` needs before it stands.
    static func timeFloor(expectedSeconds: Double?, level: SourceConsumptionConfidence) -> Double {
        let share: Double
        switch level {
        case .complete: share = completeTimeShare
        case .substantial: share = substantialTimeShare
        case .partial, .none: return 0
        }
        guard let expectedSeconds, expectedSeconds.isFinite, expectedSeconds > 0 else {
            return unknownLengthFloorSeconds
        }
        return max(minimumFloorSeconds, expectedSeconds * share)
    }

    /// What the position alone says, before time, chat, and annotations.
    static func depthConfidence(maxFraction: Double) -> SourceConsumptionConfidence {
        let fraction = SourceActivityDay.clampFraction(maxFraction)
        if fraction >= completeFraction { return .complete }
        if fraction >= substantialFraction { return .substantial }
        if fraction >= partialFraction { return .partial }
        return .none
    }

    /// A depth level, held to the time that went with it. With no time
    /// evidence at all the depth stands; with measured time short of the
    /// floor, complete falls to substantial if that floor is met, and anything
    /// still short falls to partial — the position was reached, the reading
    /// was not.
    static func timeGated(
        _ level: SourceConsumptionConfidence,
        engagedSeconds: Double?,
        expectedSeconds: Double?
    ) -> SourceConsumptionConfidence {
        guard level >= .substantial, let engagedSeconds else { return level }
        let engaged = engagedSeconds.isFinite ? max(0, engagedSeconds) : 0
        if engaged >= timeFloor(expectedSeconds: expectedSeconds, level: level) { return level }
        if level == .complete,
           engaged >= timeFloor(expectedSeconds: expectedSeconds, level: .substantial) {
            return .substantial
        }
        return .partial
    }

    static func confidence(_ signals: SourceConsumptionSignals) -> SourceConsumptionConfidence {
        if signals.readAt != nil { return .complete }
        var level = timeGated(
            depthConfidence(maxFraction: signals.maxFraction),
            engagedSeconds: signals.engagedSeconds,
            expectedSeconds: signals.expectedSeconds
        )
        if signals.chatDiscussedAt != nil {
            level = max(level, .substantial)
        }
        if signals.annotationCount > 0, let lifted = SourceConsumptionConfidence(rawValue: level.rawValue + 1) {
            level = lifted
        }
        return level
    }

    /// Whether the learner finished the source themselves: marked it read
    /// (Mark as Read, an article scrolled to its end, a Schedule completion,
    /// listening or watching logged complete), or read, heard or watched it
    /// to the end with the time that takes. Neither a chat nor an annotation
    /// finishes a source, though both lift `confidence`: what background
    /// card drafting calls a deliberate finish (docs/memory-design.md,
    /// "Drafting in the background").
    static func isFinished(_ signals: SourceConsumptionSignals) -> Bool {
        if signals.readAt != nil { return true }
        return timeGated(
            depthConfidence(maxFraction: signals.maxFraction),
            engagedSeconds: signals.engagedSeconds,
            expectedSeconds: signals.expectedSeconds
        ) == .complete
    }

    /// When the learner consumed this source, at or above `minimumConfidence`.
    ///
    /// `read_at` remains the authoritative date whenever it exists. Depth-only
    /// evidence is dated by the day the learner actually reached that point,
    /// never by `date_added` — an auto-ingested backlog would otherwise all
    /// appear consumed the day it was imported. A chat discussion later than
    /// the reading re-dates the source to the conversation: what was talked
    /// about yesterday is yesterday's material, however long ago it was read.
    static func consumedAt(
        _ signals: SourceConsumptionSignals,
        minimumConfidence: SourceConsumptionConfidence = .complete
    ) -> Date? {
        guard confidence(signals) >= minimumConfidence else { return nil }
        return [signals.readAt ?? signals.deepestActivityAt, signals.chatDiscussedAt]
            .compactMap { $0 }
            .max()
    }

    static func isConsumed(
        _ signals: SourceConsumptionSignals,
        minimumConfidence: SourceConsumptionConfidence = .complete
    ) -> Bool {
        consumedAt(signals, minimumConfidence: minimumConfidence) != nil
    }
}

/// A consumed-but-never-reviewed source, before the first-review scheduling math
/// is applied. The storage layer's output and `MemoryReviewScheduler.newItems`'
/// input.
struct MemoryReviewNewCandidate: Equatable, Sendable {
    let sourceID: String
    let title: String
    let sourceType: String
    let consumedAt: Date
}

/// A source the learner has consumed but never reviewed. It has no review history,
/// so `MemoryReviewScheduler`'s interval math has nothing to work from — the first
/// review is scheduled off the consumption date instead.
struct MemoryReviewNewItem: Identifiable, Equatable, Sendable {
    let sourceID: String
    let title: String
    let sourceType: String
    let consumedAt: Date
    let dueAt: Date
    let daysOverdue: Int

    var id: String { sourceID }
}

/// A source that is due (or overdue) for a memory refresh today, with the
/// scheduling math already applied. `daysOverdue` is always >= 0.
struct MemoryReviewDueItem: Identifiable, Equatable, Sendable {
    let sourceID: String
    let title: String
    let sourceType: String
    let lastReviewedAt: Date
    let lastScore: Double?
    let reviewCount: Int
    let dueAt: Date
    let daysOverdue: Int

    var id: String { sourceID }
}

/// A source the learner engaged with lately — discussed in an ordinary chat or
/// review session, or read, listened to, or watched. This is an attention
/// signal, not review evidence: it may reorder an already-due queue, but it
/// never changes a due date or manufactures a memory attempt.
struct MemoryTutorRecentSourceActivity: Equatable, Sendable {
    let sourceID: String
    let discussedAt: Date
}

/// The latest attention timestamp per source, folded from repeated signals.
///
/// Callers assemble the signals (discussion, reading, listening, watching) and
/// window them; this only answers "when was this last attended to". An empty
/// recency is meaningful and common — a library with no recent activity must
/// rank exactly as it did before recency existed.
struct MemoryTutorRecency: Equatable, Sendable {
    private let latestBySourceID: [String: Date]

    init(_ activity: [MemoryTutorRecentSourceActivity] = []) {
        latestBySourceID = activity.reduce(into: [String: Date]()) { result, entry in
            result[entry.sourceID] = Swift.max(
                result[entry.sourceID] ?? .distantPast,
                entry.discussedAt
            )
        }
    }

    func latest(forSourceID sourceID: String) -> Date? {
        latestBySourceID[sourceID]
    }

    func latest(forSourceIDs sourceIDs: [String]) -> Date? {
        sourceIDs.compactMap { latestBySourceID[$0] }.max()
    }
}

/// Fills `limit` slots from two rankings of the same candidates without letting
/// either starve the other.
///
/// `recentFirst` leads with what the learner most recently attended to;
/// `mostFadedFirst` leads with the oldest and hardest backlog. Half the slots
/// (rounded up) are reserved for the recent ranking, the rest go to the backlog
/// ranking, and whatever one ranking cannot fill goes to the other. When no
/// recency signal exists the two rankings are identical and this is exactly
/// `mostFadedFirst.prefix(limit)`.
func memoryTutorMergeRankings<Element>(
    recentFirst: [Element],
    mostFadedFirst: [Element],
    limit: Int,
    id: (Element) -> String
) -> [Element] {
    let cap = Swift.max(0, limit)
    guard cap > 0 else { return [] }
    let recentShare = cap - cap / 2
    var chosen: [Element] = []
    var seen = Set<String>()

    func take(_ ranking: [Element], upTo bound: Int) {
        for element in ranking {
            guard chosen.count < bound else { return }
            if seen.insert(id(element)).inserted { chosen.append(element) }
        }
    }

    take(recentFirst, upTo: recentShare)
    take(mostFadedFirst, upTo: cap)
    // Whatever the backlog could not fill returns to the recent ranking.
    take(recentFirst, upTo: cap)
    return chosen
}

enum MemoryTutorTurnPolicy {
    /// Only a learner message that follows a real tutor question is a memory
    /// attempt. Resumed opening turns may already contain learner steering text
    /// even though no question survived the failed generation.
    static func requiresRecordedAttempt(
        isFirst: Bool,
        hasMemoryPlan: Bool,
        previousTutorQuestion: String?
    ) -> Bool {
        guard !isFirst, hasMemoryPlan else { return false }
        return previousTutorQuestion?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
    }
}

/// Pure, transparent spaced-repetition scheduler for whole-source review.
/// Intervals expand with each successful revisit and stretch or shrink with the
/// last recall score. All functions are pure so the in-app card and the
/// `memory_review` MCP tool compute identical due dates from the same stats.
enum MemoryReviewScheduler {
    /// First gap after the initial review, in days.
    static let baseIntervalDays = ForeverLMCore.wholeSourceReviewBaseIntervalDays
    /// How fast the interval grows per additional successful revisit.
    static let growthFactor = ForeverLMCore.wholeSourceReviewGrowthFactor
    /// Never push a refresh further out than this.
    static let maxIntervalDays = ForeverLMCore.wholeSourceReviewMaximumIntervalDays

    /// Days to wait after the most recent review before the source is due again.
    static func intervalDays(reviewCount: Int, lastScore: Double?) -> Double {
        ForeverLMCore.wholeSourceReviewIntervalDays(
            reviewCount: reviewCount,
            lastScore: lastScore
        )
    }

    static func dueDate(for stat: MemoryReviewStat) -> Date {
        let days = intervalDays(reviewCount: stat.reviewCount, lastScore: stat.lastScore)
        return stat.lastReviewedAt.addingTimeInterval(days * 86_400)
    }

    /// The sources fading hardest right now, most-overdue first. Only items whose
    /// due date has arrived are returned; `limit` caps the daily set so the surface
    /// stays light. Ties break toward the weakest last recall score.
    static func dueItems(from stats: [MemoryReviewStat], now: Date, limit: Int) -> [MemoryReviewDueItem] {
        let due: [MemoryReviewDueItem] = stats.compactMap { stat in
            let dueAt = dueDate(for: stat)
            guard now >= dueAt else { return nil }
            let days = Int(now.timeIntervalSince(dueAt) / 86_400)
            return MemoryReviewDueItem(
                sourceID: stat.sourceID,
                title: stat.title,
                sourceType: stat.sourceType,
                lastReviewedAt: stat.lastReviewedAt,
                lastScore: stat.lastScore,
                reviewCount: stat.reviewCount,
                dueAt: dueAt,
                daysOverdue: max(0, days)
            )
        }
        return Array(
            due.sorted { a, b in
                if a.daysOverdue != b.daysOverdue { return a.daysOverdue > b.daysOverdue }
                if (a.lastScore ?? 1.0) != (b.lastScore ?? 1.0) {
                    return (a.lastScore ?? 1.0) < (b.lastScore ?? 1.0)
                }
                return a.sourceID < b.sourceID
            }
            .prefix(max(0, limit))
        )
    }

    // MARK: - First review of a consumed source

    /// How long after consuming a source before its first review comes due. Short
    /// on purpose: the point of the never-reviewed bucket is to catch material
    /// while it is still partly there, not after it has gone.
    static let firstReviewDelayDays = ForeverLMCore.wholeSourceFirstReviewDelayDays

    /// How a bounded intake set is chosen when there are more candidates than
    /// slots.
    enum IntakeOrder: Sendable {
        /// Longest-waiting first — the backlog reading of "what is overdue".
        case mostOverdueFirst
        /// Most recently consumed first — the daily-queue reading, which puts
        /// the podcast finished this week ahead of the one finished in March.
        case mostRecentlyConsumedFirst
    }

    /// Consumed-but-never-reviewed sources whose first review has come due.
    /// Mirrors `dueItems`: pure, and only returns items whose due date has
    /// arrived.
    static func newItems(
        from candidates: [MemoryReviewNewCandidate],
        now: Date,
        limit: Int,
        order: IntakeOrder = .mostOverdueFirst
    ) -> [MemoryReviewNewItem] {
        let items: [MemoryReviewNewItem] = candidates.compactMap { candidate in
            let dueAt = candidate.consumedAt.addingTimeInterval(firstReviewDelayDays * 86_400)
            guard now >= dueAt else { return nil }
            let days = Int(now.timeIntervalSince(dueAt) / 86_400)
            return MemoryReviewNewItem(
                sourceID: candidate.sourceID,
                title: candidate.title,
                sourceType: candidate.sourceType,
                consumedAt: candidate.consumedAt,
                dueAt: dueAt,
                daysOverdue: max(0, days)
            )
        }
        return Array(
            items.sorted { a, b in
                switch order {
                case .mostOverdueFirst:
                    if a.daysOverdue != b.daysOverdue { return a.daysOverdue > b.daysOverdue }
                case .mostRecentlyConsumedFirst:
                    if a.consumedAt != b.consumedAt { return a.consumedAt > b.consumedAt }
                }
                return a.sourceID < b.sourceID
            }
            .prefix(max(0, limit))
        )
    }

    /// How to split a day's `limit` between refreshes and first reviews.
    ///
    /// Neither bucket may starve the other. A learner with a long refresh backlog
    /// would never see a newly-read source if refreshes simply filled the day, and
    /// a burst of reading would bury the refreshes. So each bucket is guaranteed
    /// half the day, and whatever half a bucket cannot fill goes to the other.
    static func splitDailyLimit(dueCount: Int, newCount: Int, limit: Int) -> (due: Int, new: Int) {
        let cap = max(0, limit)
        guard cap > 0 else { return (0, 0) }

        let newShare = cap / 2
        let dueShare = cap - newShare

        let takeDue = min(dueCount, dueShare)
        let takeNew = min(newCount, newShare)

        // Hand each bucket's unused share to the other, capped by what it has.
        let slack = cap - takeDue - takeNew
        let extraDue = min(dueCount - takeDue, slack)
        let extraNew = min(newCount - takeNew, slack - extraDue)

        return (takeDue + extraDue, takeNew + extraNew)
    }

    /// The bounded first-review set for a daily queue, drawn from both intake
    /// buckets at once: sources with legacy whole-source review history that are
    /// due again, and sources consumed but never reviewed at all.
    ///
    /// Both buckets are ranked in full before the cap is applied. Filling the cap
    /// from the legacy bucket first — the shape this replaced — spent the whole
    /// day's budget on the oldest backlog whenever that backlog was larger than
    /// the cap, so a podcast finished this week could never reach the queue at
    /// all no matter how the queue was ordered afterwards. `splitDailyLimit`
    /// gives each bucket a guaranteed share and hands the unused half to the
    /// other, and the merged result leads with what was most recently consumed.
    static func firstReviewIntake(
        legacyStats: [MemoryReviewStat],
        freshCandidates: [MemoryReviewNewCandidate],
        now: Date,
        limit: Int
    ) -> [MemoryReviewNewItem] {
        let cap = Swift.max(0, limit)
        guard cap > 0 else { return [] }
        // Each bucket is ranked uncapped; only the merged set is bounded.
        let refreshes = dueItems(
            from: legacyStats,
            now: now,
            limit: legacyStats.count
        ).map { item in
            MemoryReviewNewItem(
                sourceID: item.sourceID,
                title: item.title,
                sourceType: item.sourceType,
                consumedAt: item.lastReviewedAt,
                dueAt: item.dueAt,
                daysOverdue: item.daysOverdue
            )
        }
        let fresh = newItems(
            from: freshCandidates,
            now: now,
            limit: freshCandidates.count,
            order: .mostRecentlyConsumedFirst
        )
        let split = splitDailyLimit(
            dueCount: refreshes.count,
            newCount: fresh.count,
            limit: cap
        )
        let selected = Array(refreshes.prefix(split.due)) + Array(fresh.prefix(split.new))
        return selected.sorted {
            if $0.consumedAt != $1.consumedAt { return $0.consumedAt > $1.consumedAt }
            return $0.sourceID < $1.sourceID
        }
    }
}

/// Cross-surface daily queue policy. When both buckets have work, preserve one
/// bounded intake slot and spend the rest on due concept traces, prioritizing
/// known struggles. Mac Chat, Mac voice, MCP, and iPhone all consume this exact
/// selection so "five-minute review" means the same five everywhere.
struct MemoryTutorQueueSelection: Equatable, Sendable {
    let dueItems: [DueMemoryItem]
    let firstReviews: [MemoryReviewNewItem]
    /// Stable cross-bucket order for the selected identities. Existing items use
    /// their durable item id; intake uses `MemoryTutorQueueIdentity.firstReview`.
    let orderedIDs: [String]

    static func select(
        dueItems: [DueMemoryItem],
        firstReviews: [MemoryReviewNewItem],
        availableSourceIDs: Set<String>,
        recentSourceActivity: [MemoryTutorRecentSourceActivity] = [],
        limit: Int
    ) -> MemoryTutorQueueSelection {
        let cap = max(1, min(limit, 25))
        let recency = MemoryTutorRecency(recentSourceActivity)

        let eligibleDue = dueItems
            .filter { due in
                !due.item.sources.isEmpty
                    && due.item.sources.allSatisfy { availableSourceIDs.contains($0.sourceID) }
            }
        let dueOriginalOrder = Dictionary(
            uniqueKeysWithValues: eligibleDue.enumerated().map { ($0.element.id, $0.offset) }
        )
        func dueRecency(_ due: DueMemoryItem) -> Date? {
            recency.latest(forSourceIDs: due.item.sources.map(\.sourceID))
        }
        /// The backlog reading: known struggles first, then whatever has been
        /// waiting longest. With no recency signal anywhere this is the whole
        /// ordering, exactly as it was before recency was an input.
        func isMoreFaded(_ lhs: DueMemoryItem, _ rhs: DueMemoryItem) -> Bool {
            let lhsStruggle = isStruggle(lhs)
            let rhsStruggle = isStruggle(rhs)
            if lhsStruggle != rhsStruggle { return lhsStruggle && !rhsStruggle }
            if lhs.schedule.dueAt != rhs.schedule.dueAt {
                return lhs.schedule.dueAt < rhs.schedule.dueAt
            }
            return (dueOriginalOrder[lhs.id] ?? .max) < (dueOriginalOrder[rhs.id] ?? .max)
        }
        let dueMostFadedFirst = eligibleDue.sorted(by: isMoreFaded)
        let dueRecentFirst = eligibleDue.sorted { lhs, rhs in
            let lhsRecent = dueRecency(lhs)
            let rhsRecent = dueRecency(rhs)
            if lhsRecent != rhsRecent {
                return (lhsRecent ?? .distantPast) > (rhsRecent ?? .distantPast)
            }
            return isMoreFaded(lhs, rhs)
        }

        let representedSourceIDs = Set(eligibleDue.flatMap { $0.item.sources.map(\.sourceID) })
        let eligibleFirstReviews = firstReviews.filter {
            availableSourceIDs.contains($0.sourceID)
                && !representedSourceIDs.contains($0.sourceID)
        }
        let firstOriginalOrder = Dictionary(
            uniqueKeysWithValues: eligibleFirstReviews.enumerated().map {
                ($0.element.sourceID, $0.offset)
            }
        )
        // Intake carries its own attention timestamp: finishing a source is the
        // same kind of signal as talking about one, and for something consumed
        // away from the app it is the only signal there is.
        func firstReviewAttention(_ item: MemoryReviewNewItem) -> Date {
            max(recency.latest(forSourceID: item.sourceID) ?? .distantPast, item.consumedAt)
        }
        let orderedFirstReviews = eligibleFirstReviews.sorted { lhs, rhs in
            let lhsAttention = firstReviewAttention(lhs)
            let rhsAttention = firstReviewAttention(rhs)
            if lhsAttention != rhsAttention { return lhsAttention > rhsAttention }
            return (firstOriginalOrder[lhs.sourceID] ?? .max)
                < (firstOriginalOrder[rhs.sourceID] ?? .max)
        }
        // One slot is always held for intake when any exists, so a long refresh
        // backlog can never hide newly consumed material completely.
        let dueLimit = orderedFirstReviews.isEmpty ? cap : max(0, cap - 1)
        // Half the concept slots go to what the learner recently attended to and
        // the rest to the faded backlog, each yielding its unused share to the
        // other. Ranking then capping — rather than capping a single backlog
        // ranking — is what keeps this week's material reachable at all.
        let selectedDue = memoryTutorMergeRankings(
            recentFirst: dueRecentFirst,
            mostFadedFirst: dueMostFadedFirst,
            limit: dueLimit,
            id: \.id
        )
        let selectedFirst = Array(
            orderedFirstReviews.prefix(max(0, cap - selectedDue.count))
        )
        struct OrderedIdentity {
            let id: String
            let recentAt: Date?
            let isStruggle: Bool
            let originalIndex: Int
        }
        var combined: [OrderedIdentity] = selectedDue.enumerated().map { index, due in
            OrderedIdentity(
                id: due.id,
                recentAt: dueRecency(due),
                isStruggle: isStruggle(due),
                originalIndex: index
            )
        }
        combined.append(contentsOf: selectedFirst.enumerated().map { index, item in
            OrderedIdentity(
                id: MemoryTutorQueueIdentity.firstReview(sourceID: item.sourceID),
                recentAt: recency.latest(forSourceID: item.sourceID),
                isStruggle: false,
                originalIndex: selectedDue.count + index
            )
        })
        // Recency leads the session. A struggle the learner last touched in
        // March is still worth revisiting, but opening on it is what made a
        // daily review read as somebody else's backlog.
        let orderedIDs = combined.sorted { lhs, rhs in
            if lhs.recentAt != rhs.recentAt {
                return (lhs.recentAt ?? .distantPast) > (rhs.recentAt ?? .distantPast)
            }
            if lhs.isStruggle != rhs.isStruggle { return lhs.isStruggle && !rhs.isStruggle }
            return lhs.originalIndex < rhs.originalIndex
        }.map(\.id)
        return MemoryTutorQueueSelection(
            dueItems: selectedDue,
            firstReviews: selectedFirst,
            orderedIDs: orderedIDs
        )
    }

    static func isStruggle(_ due: DueMemoryItem) -> Bool {
        let context = due.item.learnerContext?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !context.isEmpty
            || due.schedule.lapseCount > 0
            || due.schedule.difficulty > 0.5
    }
}

// MARK: - Prior struggle projection

/// Structured, bounded evidence that a future tutor can use after retrieval has
/// been attempted. Nothing here is inferred from feedback prose: the missing
/// rubric elements and misconception come from the grader's durable JSON fields.
struct MemoryStruggleEvidence: Codable, Equatable, Sendable, Identifiable {
    let attemptID: String
    let attemptedAt: Date
    let attemptType: MemoryAttemptType
    let gradeState: MemoryGradeState
    let scheduleRating: MemoryScheduleRating?
    let score: Double?
    let prompt: String
    let learnerAnswer: String
    let feedback: String?
    let gradingError: String?
    let retrievalQuality: String?
    let missingRubricElements: [String]
    let misconception: String?
    let evidenceJSON: String?

    var id: String { attemptID }
}

struct MemoryStruggleProjection: Codable, Equatable, Sendable, Identifiable {
    let memoryItemID: String
    let target: String
    let rubricJSON: String
    let learnerContext: String?
    let evidence: [MemoryStruggleEvidence]

    var id: String { memoryItemID }
}

/// Pure cross-device selection of the attempts most useful for adapting a later
/// review. Failures and explicit `.again`/`.hard` judgments qualify; successful
/// recall never enters merely because its feedback happens to sound negative.
enum MemoryTutorStruggleProjector {
    static func project(
        item: MemoryItem,
        attempts: [MemoryAttempt],
        limit: Int = 3
    ) -> MemoryStruggleProjection {
        let boundedLimit = Swift.max(0, limit)
        let evidence = attempts
            .filter { attempt in
                guard attempt.memoryItemID == item.id else { return false }
                if attempt.gradeState == .failed { return true }
                guard attempt.gradeState == .graded else { return false }
                return attempt.scheduleRating == .again || attempt.scheduleRating == .hard
            }
            .sorted {
                if $0.attemptedAt != $1.attemptedAt {
                    return $0.attemptedAt > $1.attemptedAt
                }
                return $0.id < $1.id
            }
            .prefix(boundedLimit)
            .map { attempt in
                let structured = attempt.evidenceJSON.flatMap { json in
                    try? JSONDecoder().decode(
                        StructuredMemoryAttemptEvidence.self,
                        from: Data(json.utf8)
                    )
                }
                return MemoryStruggleEvidence(
                    attemptID: attempt.id,
                    attemptedAt: attempt.attemptedAt,
                    attemptType: attempt.attemptType,
                    gradeState: attempt.gradeState,
                    scheduleRating: attempt.scheduleRating,
                    score: attempt.score,
                    prompt: attempt.prompt,
                    learnerAnswer: attempt.learnerAnswer,
                    feedback: attempt.feedback,
                    gradingError: attempt.gradingError,
                    retrievalQuality: structured?.retrievalQuality,
                    missingRubricElements: structured?.missingRubricElements ?? [],
                    misconception: structured?.misconception,
                    evidenceJSON: attempt.evidenceJSON
                )
            }
        return MemoryStruggleProjection(
            memoryItemID: item.id,
            target: item.target,
            rubricJSON: item.rubricJSON,
            learnerContext: item.learnerContext,
            evidence: Array(evidence)
        )
    }

    private struct StructuredMemoryAttemptEvidence: Decodable {
        let retrievalQuality: String?
        let missingRubricElements: [String]
        let misconception: String?

        private enum CodingKeys: String, CodingKey {
            case retrievalQuality = "retrieval_quality"
            case missingRubricElements = "missing_rubric_elements"
            case misconception
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            retrievalQuality = try values.decodeIfPresent(String.self, forKey: .retrievalQuality)
            missingRubricElements = try values.decodeIfPresent(
                [String].self,
                forKey: .missingRubricElements
            ) ?? []
            misconception = try values.decodeIfPresent(String.self, forKey: .misconception)
        }
    }
}

/// App-owned, session-scoped identity for a source that has not produced its
/// first durable MemoryItem yet. It is never stored as the MemoryItem ID; the
/// latter is created only after a grounded learner attempt.
enum MemoryTutorQueueIdentity {
    private static let firstReviewPrefix = "first-review:"

    static func firstReview(sourceID: String) -> String {
        firstReviewPrefix + sourceID
    }

    static func firstReviewSourceID(from value: String) -> String? {
        guard value.hasPrefix(firstReviewPrefix) else { return nil }
        let sourceID = String(value.dropFirst(firstReviewPrefix.count))
        return sourceID.isEmpty ? nil : sourceID
    }
}

// MARK: - Due selection

extension MemoryTutorScheduler {
    /// The bounded candidate pool a daily queue is chosen from.
    ///
    /// `recentSourceActivity` matters here and not only downstream: this is where
    /// the pool is capped, and a pool capped by "most overdue" alone cannot be
    /// reordered into containing this week's material later. Half the slots
    /// (rounded up) are therefore reserved for the sources most recently attended
    /// to. With no recency signal the two rankings coincide and the result is the
    /// same most-faded-first pool as before.
    static func dueItems(
        items: [MemoryItem],
        schedules: [String: MemorySchedule],
        now: Date,
        limit: Int,
        recentSourceActivity: [MemoryTutorRecentSourceActivity] = []
    ) -> [DueMemoryItem] {
        let due = items.compactMap { item -> DueMemoryItem? in
            guard item.status == .active else { return nil }
            let schedule = schedules[item.id] ?? initialSchedule(for: item)
            // A new item is never due; the card queue introduces it.
            guard !schedule.isNew, schedule.dueAt <= now else { return nil }
            let secondsOverdue = max(0, now.timeIntervalSince(schedule.dueAt))
            return DueMemoryItem(
                item: item,
                schedule: schedule,
                daysOverdue: Int(secondsOverdue / secondsPerDay)
            )
        }

        func isMoreFaded(_ lhs: DueMemoryItem, _ rhs: DueMemoryItem) -> Bool {
            let lhsStruggle = MemoryTutorQueueSelection.isStruggle(lhs)
            let rhsStruggle = MemoryTutorQueueSelection.isStruggle(rhs)
            if lhsStruggle != rhsStruggle {
                return lhsStruggle && !rhsStruggle
            }
            if lhs.schedule.dueAt != rhs.schedule.dueAt {
                return lhs.schedule.dueAt < rhs.schedule.dueAt
            }
            return lhs.item.id < rhs.item.id
        }
        let mostFadedFirst = due.sorted(by: isMoreFaded)
        guard !recentSourceActivity.isEmpty else {
            return Array(mostFadedFirst.prefix(max(0, limit)))
        }
        let recency = MemoryTutorRecency(recentSourceActivity)
        let recentFirst = due.sorted { lhs, rhs in
            let lhsRecent = recency.latest(forSourceIDs: lhs.item.sources.map(\.sourceID))
            let rhsRecent = recency.latest(forSourceIDs: rhs.item.sources.map(\.sourceID))
            if lhsRecent != rhsRecent {
                return (lhsRecent ?? .distantPast) > (rhsRecent ?? .distantPast)
            }
            return isMoreFaded(lhs, rhs)
        }
        return memoryTutorMergeRankings(
            recentFirst: recentFirst,
            mostFadedFirst: mostFadedFirst,
            limit: max(0, limit),
            id: \.id
        )
    }
}
