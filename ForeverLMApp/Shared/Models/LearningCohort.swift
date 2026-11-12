import Foundation

/// Why a source is in today's cohort. The role is not decoration: it decides what
/// the planner is allowed to do with the source, and it is the difference between
/// a review session and a synthesis session.
enum CohortRole: String, Codable, Equatable, Sendable {
    /// Consumed recently and not yet reviewed. The material the session is about.
    case spine
    /// Discussed before and due again, or consumed a while ago and still untouched.
    case spacing
    /// Pulled in only because it is semantically close to a spine source from a
    /// different stretch of time. Present to be collided with, not reviewed.
    ///
    /// A bridge may be something the learner only partly got through. Syntopic
    /// reading — a few sources deeply, many shallowly — means the shallow ones
    /// still carry context worth colliding with, even though they could never
    /// carry a review of their own.
    case bridge
}

/// One source in a cohort, with the evidence that put it there.
struct CohortSource: Identifiable, Equatable, Sendable {
    let sourceID: String
    let title: String
    let sourceType: String
    let role: CohortRole
    let consumedAt: Date?
    let lastDiscussedAt: Date?
    let reviewCount: Int
    /// How much of it actually landed. A bridge is allowed to be a partial read;
    /// spine and spacing never are.
    let confidence: SourceConsumptionConfidence
    /// For a bridge, the spine source it was drawn against.
    let bridgeTo: String?
    /// Plain-language justification, carried into the planner prompt so the model
    /// knows whether it is revisiting, refreshing, or connecting.
    let reason: String
    /// How the learner worked with it: time, depth, chat, annotations.
    var engagement: CohortEngagement = .none

    var id: String { sourceID }
}

/// How a source was actually engaged with, from the engagement ledger
/// (docs/memory-design.md, "The engagement ledger"). What ranks yesterday's
/// reading and what the tutor is told about how the learner met the source.
struct CohortEngagement: Equatable, Sendable {
    /// Seconds spent with the source across its activity days.
    var engagedSeconds: Double = 0
    /// Deepest point reached, 0...1; 0 when unmeasured.
    var depth: Double = 0
    /// The most recent ordinary chat the learner wrote in with the source
    /// attached or carried on an exchange.
    var chatDiscussedAt: Date? = nil
    /// Highlights and notes on the source.
    var annotationCount: Int = 0

    static let none = CohortEngagement()

    var isChatDiscussed: Bool { chatDiscussedAt != nil }
    var isAnnotated: Bool { annotationCount > 0 }

    /// Time weighted by depth: the reading that both went far and took a while
    /// outranks the one that only did one of the two.
    var score: Double { engagedSeconds * max(depth, 0) }
}

/// A source eligible for selection, with the two facts selection turns on:
/// when it was consumed, and what its review history looks like.
struct CohortCandidate: Equatable, Sendable {
    let sourceID: String
    let title: String
    let sourceType: String
    let consumedAt: Date
    let confidence: SourceConsumptionConfidence
    let reviewCount: Int
    let lastDiscussedAt: Date?
    /// The rung the source's graded contour recalls put it on
    /// (`ForeverLMCore.memoryReviewRung`). nil for a source that has only
    /// the older, count-based history, which then stands in for the rung.
    var contourRung: Int? = nil
    /// How the learner engaged with it; ranks the spine.
    var engagement: CohortEngagement = .none
    /// The learner finished it themselves (`SourceConsumption.isFinished`):
    /// what background card drafting calls a deliberate finish. False for a
    /// chat, and where the caller did not say.
    var isFinished: Bool = false

    /// Where the source stands on the ladder: the coverage-derived rung when a
    /// memory review has graded it, otherwise how often it has been discussed.
    var rung: Int { contourRung ?? reviewCount }
}

/// A source the learner opened recently but that fell below the bar for a
/// review of its own: too little time, too little depth. Named in the
/// briefing so the tutor can acknowledge the day as it was, never quizzed.
struct CohortTouchedSource: Identifiable, Equatable, Sendable {
    let sourceID: String
    let title: String
    let sourceType: String
    let lastActivityAt: Date
    let engagedSeconds: Double
    let depth: Double

    var id: String { sourceID }
}

/// The day's totals: what the learner took in since the last day, said at the
/// top of the briefing and under the Memory row so the picker can be checked
/// against the learner's own memory of the day.
struct MemoryReviewLedger: Equatable, Sendable {
    /// Sources with any recorded activity in the window.
    var sourceCount: Int = 0
    /// Seconds engaged across them.
    var engagedSeconds: Double = 0
    /// Of those, how many were discussed in a chat the learner wrote in.
    var chatDiscussedCount: Int = 0
    /// Of those, how many were listened to or watched rather than read.
    var listenedCount: Int = 0

    var isEmpty: Bool { sourceCount == 0 }

    /// The window the ledger and the touched list cover: from the start of
    /// yesterday, by the local calendar. The same stretch the guaranteed
    /// first pass draws from, said in the learner's own days.
    static func windowStart(now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -1, to: today) ?? today.addingTimeInterval(-MemoryTutorScheduler.secondsPerDay)
    }

    static let windowLabel = "Yesterday and today"

    /// "Yesterday and today: 9 sources · 2h 10m · 3 discussed in chats · 2 listened"
    func line(label: String = MemoryReviewLedger.windowLabel) -> String {
        guard !isEmpty else { return "\(label): nothing recorded" }
        var parts: [String] = []
        parts.append(sourceCount == 1 ? "1 source" : "\(sourceCount) sources")
        parts.append(Self.durationLabel(seconds: engagedSeconds))
        if chatDiscussedCount > 0 {
            parts.append("\(chatDiscussedCount) discussed in chats")
        }
        if listenedCount > 0 {
            parts.append("\(listenedCount) listened")
        }
        return "\(label): " + parts.joined(separator: " · ")
    }

    static func durationLabel(seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        if minutes > 0 { return "\(minutes)m" }
        return total > 0 ? "under a minute" : "no time recorded"
    }
}

/// What the selector chose, and what it had to leave out.
struct CohortSelection: Equatable, Sendable {
    var spine: [CohortCandidate] = []
    var spacing: [CohortCandidate] = []
    /// Eligible but cut by the cap. Surfaced rather than swallowed: a silent
    /// truncation reads to the learner as "we covered everything" when it didn't.
    /// Counts a guaranteed pass (`CohortSelector.isGuaranteedPass`) only past
    /// `CohortSelector.maxGuaranteedPasses`; under it the cap cannot cut one.
    var droppedSpine: Int = 0
    var droppedSpacing: Int = 0
}

/// Today's material. Assembled by query at session time and never stored — there
/// is no cohort record to go stale, and no per-idea schedule to maintain.
struct LearningCohort: Equatable, Sendable {
    let assembledAt: Date
    let windowDays: Int
    let sources: [CohortSource]
    /// Sources whose understanding document records something unresolved.
    let unfinished: [String]
    let droppedSpine: Int
    let droppedSpacing: Int
    /// Nothing was due; these are the least recently touched sources, offered so
    /// the Memory action still opens on material. The tutor is told to say so.
    var isBacklogOnly: Bool = false
    /// Opened since the last day but below the bar for a review: named, not quizzed.
    var touched: [CohortTouchedSource] = []
    /// What the learner took in since the last day, in totals.
    var ledger: MemoryReviewLedger? = nil

    var isEmpty: Bool { sources.isEmpty }

    func sources(in role: CohortRole) -> [CohortSource] {
        sources.filter { $0.role == role }
    }
}

/// Selection: bounded, deterministic, and stateless.
///
/// The spacing curve is derived rather than stored. There is no per-idea
/// scheduler because the unit being spaced is the *source*, and a source's
/// review history is already in `review_sessions` — which means nothing here
/// syncs, and two Macs cannot disagree about what is due.
enum CohortSelector {
    /// A rolling window rather than a calendar week, so a quiet week produces a
    /// pure spacing session instead of an empty one.
    static let windowDays = 10
    static let maxBridgesPerSpine = 1

    /// How many bridges a review of this length carries. See
    /// `MemoryReviewBudget.bridgeSlots(minutes:)`.
    static func maxBridges(budgetMinutes: Int) -> Int {
        MemoryReviewBudget.bridgeSlots(minutes: budgetMinutes)
    }

    /// How the day's source slots are shared between recent reading and
    /// material due again. Spine comes first, because the session is about it,
    /// but when anything is due about a third of the slots are kept for it, so
    /// a heavy week of reading never starves the spacing set entirely. Slots
    /// one side leaves empty go to the other.
    struct Caps: Equatable, Sendable {
        let spine: Int
        let spacing: Int
    }

    static func caps(budgetMinutes: Int, spineCount: Int, spacingCount: Int) -> Caps {
        caps(
            slots: MemoryReviewBudget.sourceSlots(minutes: budgetMinutes),
            spineCount: spineCount,
            spacingCount: spacingCount
        )
    }

    /// The same split over an explicit number of slots — what is left of the
    /// budget once yesterday's guaranteed passes have taken theirs. Zero slots
    /// yields zero of each rather than a negative cap.
    static func caps(slots: Int, spineCount: Int, spacingCount: Int) -> Caps {
        guard slots > 0 else { return Caps(spine: 0, spacing: 0) }
        let reservedSpacing = spacingCount == 0 ? 0 : min(spacingCount, max(1, slots / 3))
        let spine = min(spineCount, max(0, slots - reservedSpacing))
        let spacing = min(spacingCount, max(0, slots - spine))
        return Caps(spine: spine, spacing: spacing)
    }

    /// How recently a never-discussed source must have been consumed for its
    /// first pass to be guaranteed. Measured in whole days by the clock
    /// (`days(from:to:)`), so `1` covers anything taken in since the day before
    /// yesterday's review ran — yesterday's reading, and the day before's if
    /// yesterday's review never reached it.
    ///
    /// Retrieval the day after is the review's whole point: sleep has passed,
    /// the material is still recoverable, and a first unaided recall is what
    /// tells the ledger which ideas landed. A budget that dropped it would
    /// defer that recall by weeks, until the source resurfaced as backlog. So
    /// these sources are not cut by the day's cap, up to `maxGuaranteedPasses`;
    /// the budget then governs how deep each one goes, and the tutor names
    /// what did not fit.
    static let guaranteedPassDays = 1

    /// How many guaranteed passes one review will carry. The guarantee assumes
    /// a heavy day of reading — thirty-odd sources — not a bulk import: a
    /// library that had just taken in a Notebook's worth of papers
    /// produced a review over 166 sources, a briefing the model had to read in
    /// one go, and a CloudKit record too large to sync. The ceiling is what the
    /// longest budget Settings offers can cover, two hours at the planning rate,
    /// so no review is ever planned longer than the learner could have asked
    /// for. Whatever does not fit stays spine for the rest of the window and
    /// then backlog, and takes its first pass on the following days.
    static var maxGuaranteedPasses: Int {
        MemoryReviewBudget.sourceSlots(minutes: MemoryReviewBudget.maximumMinutes)
    }

    /// Whether a candidate's first pass is guaranteed today: consumed within
    /// `guaranteedPassDays` and not yet reviewed.
    static func isGuaranteedPass(_ candidate: CohortCandidate, now: Date) -> Bool {
        candidate.reviewCount == 0
            && days(from: candidate.consumedAt, to: now) <= guaranteedPassDays
    }

    /// Spine and spacing require real depth; a source someone abandoned early
    /// cannot carry a review of its own. Bridges are the deliberate exception.
    static let selectableConfidence: SourceConsumptionConfidence = .substantial
    static let bridgeableConfidence: SourceConsumptionConfidence = .partial

    /// Expanding intervals in days, indexed by rung. The constants live in
    /// `ForeverLMCore` because the website computes due dates too. Capped
    /// at the last entry, so a well-known source keeps resurfacing twice a year
    /// rather than falling out of rotation forever.
    static var intervals: [Int] { ForeverLMCore.memoryReviewLadderDays }

    static func interval(forReviewCount count: Int) -> Int {
        ForeverLMCore.memoryReviewIntervalDays(rung: count)
    }

    /// The interval a candidate is measured against: its coverage-derived rung
    /// when the memory review has graded it, else its discussion count.
    static func interval(for candidate: CohortCandidate) -> Int {
        ForeverLMCore.memoryReviewIntervalDays(rung: candidate.rung)
    }

    static func days(from start: Date, to end: Date) -> Int {
        Int(max(0, end.timeIntervalSince(start)) / MemoryTutorScheduler.secondsPerDay)
    }

    /// Splits eligible candidates into the session's spine and its spacing set.
    ///
    /// A source consumed inside the window and never reviewed is spine. Anything
    /// else that is due — reviewed long enough ago for its interval, or consumed
    /// before the window and still never reviewed — is spacing. The backlog case
    /// matters: without it, a paper read three weeks ago and never reviewed would
    /// never become due at all.
    ///
    /// `budgetMinutes` is the learner's daily time budget; it decides how many
    /// of each the day gets (`caps(budgetMinutes:spineCount:spacingCount:)`),
    /// except that a source consumed since yesterday and never reviewed is in
    /// regardless (`isGuaranteedPass(_:now:)`), up to `maxGuaranteedPasses`: a
    /// heavy day of reading yields a review longer than the budget rather than
    /// a first recall deferred by weeks, while a bulk import spills into the
    /// following days. The tutor works breadth first and names what did not fit.
    static func select(
        candidates: [CohortCandidate],
        now: Date,
        budgetMinutes: Int = MemoryReviewBudget.defaultMinutes
    ) -> CohortSelection {
        var selection = CohortSelection()

        var spineCandidates: [CohortCandidate] = []
        var spacingCandidates: [CohortCandidate] = []

        for candidate in candidates {
            let consumedDaysAgo = days(from: candidate.consumedAt, to: now)
            if candidate.reviewCount == 0 {
                if consumedDaysAgo <= windowDays {
                    spineCandidates.append(candidate)
                } else {
                    spacingCandidates.append(candidate)
                }
                continue
            }
            guard let lastDiscussed = candidate.lastDiscussedAt else {
                // A review count with no timestamp is incoherent; treat it as due
                // rather than dropping the source silently.
                spacingCandidates.append(candidate)
                continue
            }
            let elapsed = days(from: lastDiscussed, to: now)
            if elapsed >= interval(for: candidate) {
                spacingCandidates.append(candidate)
            }
        }

        // Ranked by how the learner worked with each source, so the session
        // opens on what they engaged with rather than on what they touched
        // last; the cap on older reading then cuts the least engaged first.
        spineCandidates.sort(by: engagementRank)
        // Most overdue first, measured against each source's own interval so a
        // long-interval source does not always outrank a short-interval one.
        spacingCandidates.sort { lhs, rhs in
            let lhsScore = overdueRatio(lhs, now: now)
            let rhsScore = overdueRatio(rhs, now: now)
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            return lhs.sourceID < rhs.sourceID
        }

        // Yesterday's reading takes its slots first, up to the ceiling one
        // review can carry; whatever the budget has left is shared between older
        // new reading and the spacing set as before. Guaranteed passes past the
        // ceiling rejoin the ranked spine, so the most engaged of them still
        // compete for any slot left and the rest are counted as dropped.
        let guaranteed = Array(
            spineCandidates.filter { isGuaranteedPass($0, now: now) }.prefix(maxGuaranteedPasses)
        )
        let guaranteedIDs = Set(guaranteed.map(\.sourceID))
        let remainingSpine = spineCandidates.filter { !guaranteedIDs.contains($0.sourceID) }
        let slots = MemoryReviewBudget.sourceSlots(minutes: budgetMinutes)
        let caps = caps(
            slots: max(0, slots - guaranteed.count),
            spineCount: remainingSpine.count,
            spacingCount: spacingCandidates.count
        )
        selection.spine = guaranteed + Array(remainingSpine.prefix(caps.spine))
        selection.droppedSpine = max(0, remainingSpine.count - caps.spine)
        selection.spacing = Array(spacingCandidates.prefix(caps.spacing))
        selection.droppedSpacing = max(0, spacingCandidates.count - caps.spacing)
        return selection
    }

    /// How many sources to offer when nothing is due.
    static let maxBacklog = 3

    /// The least recently touched consumed sources, for a day with nothing due.
    ///
    /// "Touched" is the last discussion when there was one, otherwise the
    /// consumption itself; the source that has gone longest without either is
    /// the one most worth a question. Deterministic ties, like `select`.
    static func backlog(
        candidates: [CohortCandidate],
        now: Date,
        limit: Int = maxBacklog
    ) -> [CohortCandidate] {
        let ordered = candidates.sorted { lhs, rhs in
            let lhsTouched = lhs.lastDiscussedAt ?? lhs.consumedAt
            let rhsTouched = rhs.lastDiscussedAt ?? rhs.consumedAt
            if lhsTouched != rhsTouched { return lhsTouched < rhsTouched }
            return lhs.sourceID < rhs.sourceID
        }
        return Array(ordered.prefix(max(0, limit)))
    }

    static func backlogReason(candidate: CohortCandidate, now: Date) -> String {
        let touched = candidate.lastDiscussedAt ?? candidate.consumedAt
        let elapsed = days(from: touched, to: now)
        return candidate.lastDiscussedAt == nil
            ? "Nothing is due today. Taken in \(elapsed)d ago and never reviewed."
            : "Nothing is due today. Last reviewed \(elapsed)d ago; the longest-untouched source."
    }

    static func overdueRatio(_ candidate: CohortCandidate, now: Date) -> Double {
        let reference = candidate.lastDiscussedAt ?? candidate.consumedAt
        let elapsed = Double(days(from: reference, to: now))
        let due = Double(interval(for: candidate))
        guard due > 0 else { return elapsed }
        return elapsed / due
    }

    /// Which time bucket a candidate falls in. Bridges must cross buckets — that
    /// is the whole point of them, and it is what makes the resulting question
    /// something neither source could have produced alone.
    static func timeBucket(_ date: Date, now: Date) -> Int {
        let elapsed = days(from: date, to: now)
        if elapsed <= windowDays { return 0 }
        if elapsed <= 45 { return 1 }
        if elapsed <= 150 { return 2 }
        return 3
    }

    /// The spine's order: what the learner talked about first, then what they
    /// marked up, then time weighted by depth, then freshness. Deterministic
    /// ties, like everything else here.
    static func engagementRank(_ lhs: CohortCandidate, _ rhs: CohortCandidate) -> Bool {
        let lhsChat = lhs.engagement.chatDiscussedAt
        let rhsChat = rhs.engagement.chatDiscussedAt
        switch (lhsChat, rhsChat) {
        case let (l?, r?) where l != r: return l > r
        case (.some, .none): return true
        case (.none, .some): return false
        default: break
        }
        if lhs.engagement.isAnnotated != rhs.engagement.isAnnotated { return lhs.engagement.isAnnotated }
        if lhs.engagement.score != rhs.engagement.score { return lhs.engagement.score > rhs.engagement.score }
        if lhs.consumedAt != rhs.consumedAt { return lhs.consumedAt > rhs.consumedAt }
        return lhs.sourceID < rhs.sourceID
    }

    /// The engagement facts as a clause for the tutor: how the learner met the
    /// source decides how it is opened. Empty when nothing was measured.
    static func engagementNote(_ engagement: CohortEngagement, now: Date) -> String {
        var clauses: [String] = []
        if let chat = engagement.chatDiscussedAt {
            let elapsed = days(from: chat, to: now)
            let when = elapsed == 0 ? "within the last day" : "\(elapsed)d ago"
            clauses.append(
                "DISCUSSED IN A CHAT \(when): open on what they took away from that conversation, not on the text."
            )
        }
        if engagement.isAnnotated {
            clauses.append(
                engagement.annotationCount == 1
                    ? "They highlighted it once."
                    : "They highlighted it \(engagement.annotationCount) times."
            )
        }
        if engagement.engagedSeconds > 0 {
            clauses.append("About \(MemoryReviewLedger.durationLabel(seconds: engagement.engagedSeconds)) with it.")
        }
        return clauses.joined(separator: " ")
    }

    static func reason(for role: CohortRole, candidate: CohortCandidate, now: Date) -> String {
        let base = baseReason(for: role, candidate: candidate, now: now)
        let note = engagementNote(candidate.engagement, now: now)
        return note.isEmpty ? base : base + " " + note
    }

    private static func baseReason(for role: CohortRole, candidate: CohortCandidate, now: Date) -> String {
        let consumedDaysAgo = days(from: candidate.consumedAt, to: now)
        switch role {
        case .spine:
            // "Reviewed", not "discussed": a chat about the source is a
            // different fact, said by the engagement note beside this, and the
            // two words together read as a contradiction.
            let taken = consumedDaysAgo == 0
                ? "Taken in within the last day, not reviewed yet."
                : "Taken in \(consumedDaysAgo)d ago, not reviewed yet."
            // Said to the planner and the tutor so a long day is handled by
            // going lighter per source, never by leaving one out.
            return isGuaranteedPass(candidate, now: now)
                ? taken + " Its first pass is guaranteed today; keep it to the contour if time is short."
                : taken
        case .spacing:
            if let last = candidate.lastDiscussedAt {
                let elapsed = days(from: last, to: now)
                let due = interval(for: candidate)
                return "Last reviewed \(elapsed)d ago, \(candidate.reviewCount) time(s); due at \(due)d."
            }
            return "Taken in \(consumedDaysAgo)d ago and still never reviewed."
        case .bridge:
            let base = "Semantically close to today's material, from \(consumedDaysAgo)d ago."
            // Said plainly so the tutor can say it too, rather than quizzing them
            // on the half of a source they never reached.
            return candidate.confidence == .partial
                ? base + " They only got part of the way through this one."
                : base
        }
    }
}
