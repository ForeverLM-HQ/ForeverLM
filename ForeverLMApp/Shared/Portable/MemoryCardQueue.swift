#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif

/// A notebook the learner needs soon: a calendar block for it, or the end of
/// its Goal. The caller resolves it; the queue looks nothing up.
///
/// `sourceIDs` are the library sources in the notebook, in the ids the items'
/// anchors use (canonical ids, with team copies' aliases already resolved). A
/// card belongs to the notebook when one of its anchors is among them, or when
/// its `goalID` is the notebook's id.
struct MemoryCardDeadline: Equatable, Sendable {
    let notebookID: String
    /// When the notebook is needed: the block's start, or the Goal's end.
    let at: Date
    let sourceIDs: Set<String>

    init(notebookID: String, at: Date, sourceIDs: Set<String>) {
        self.notebookID = notebookID
        self.at = at
        self.sourceIDs = sourceIDs
    }
}

/// Today's card review: which kept cards are asked today, and in what order.
///
/// One function, `today`, used by every surface that deals or counts the day's
/// cards (the Mac's card review, the iPhone, its widget, the voice queue and
/// MCP), so they all agree. Foundation only, and no regex or URL parsing: it
/// compiles into the website's WebAssembly core.
///
/// The order:
/// - **(a) Deadline cards.** Due and eligible new cards of notebooks needed
///   within `deadlineHorizon` (a calendar block or a Goal's end), the soonest
///   notebook first; within a notebook, due cards most overdue first, then new
///   cards oldest kept first. New cards here are not held to the daily
///   allowance: the notebook is needed before tomorrow's allowance comes.
/// - **(b) Due cards**, most overdue first.
/// - **(c) New cards**, oldest kept first, up to the day's allowance:
///   `newPerDay`, less the new cards already introduced today (their first
///   graded attempt fell today, wherever it was made) and the new cards in (a).
///   An item born with its first graded attempt, a `.discovery` (a walkthrough
///   or course-quiz miss kept at once, a voice or assistant first review), was
///   never a new card dealt from the allowance, so it does not use it up.
///
/// A new card is eligible from the start of the local day after it was kept
/// (`MemoryTutorScheduler.firstEligibleAt`). The list is cut where the next card
/// would overrun `budgetMinutes`, at the planning rates below; what is left
/// waits for another day and is counted in `dueLeftOver` and `newLeftOver`.
enum MemoryCardQueue {
    /// The daily allowance of new cards when the learner has set none
    /// (`memory.new_cards_per_day`).
    static let defaultNewPerDay = 10
    /// The learner's allowance, Settings › Background › Memory review: synced
    /// (`SyncedPreferenceKeys.synced`), a statement about the learner's day.
    /// It also sets how many sources ForeverLM drafts cards from in the
    /// background each day (`AutomaticCardDrafting.dailySourceLimit`).
    static let newPerDayPreferenceKey = "memory.new_cards_per_day"
    /// What Settings offers. A value off the list, set over MCP, is kept
    /// after clamping.
    static let newPerDayChoices = [5, 10, 15, 20, 30, 50]
    static let newPerDayRange = 1...100

    static func clampNewPerDay(_ count: Int) -> Int {
        min(max(count, newPerDayRange.lowerBound), newPerDayRange.upperBound)
    }

    /// The day's allowance from the synced row's value: the learner's number,
    /// clamped, or `defaultNewPerDay` when the row is absent. Every client
    /// reads `memory.new_cards_per_day` this way — the Mac from its defaults,
    /// the iPhone from CloudKit, the website (`memoryNewCardsPerDay`) from its
    /// Preference records — so they deal the same new cards.
    static func newPerDay(stored: Int?) -> Int {
        guard let stored else { return defaultNewPerDay }
        return clampNewPerDay(stored)
    }
    /// How far ahead a block or Goal end puts its notebook's cards first.
    static let deadlineHorizon: TimeInterval = 36 * 3_600
    /// Planning rates, not promises (like `MemoryReviewBudget.minutesPerSource`):
    /// a card seen before is a front, a moment's recall, the back and a grade; a
    /// new card is read more slowly, the why included.
    static let secondsPerDueCard = 30
    static let secondsPerNewCard = 60

    /// Which part of the order put a card in today's list.
    enum Bucket: String, Codable, Sendable {
        case deadline
        case due
        case new
    }

    struct Entry: Equatable, Sendable, Identifiable {
        let item: MemoryItem
        let schedule: MemorySchedule
        let bucket: Bucket
        /// The notebook whose block or Goal end put the card first; nil outside (a).
        let notebookID: String?
        /// Whole days since the card fell due; 0 for a new card.
        let daysOverdue: Int

        var id: String { item.id }
        var isNew: Bool { schedule.isNew }
    }

    struct Today: Equatable, Sendable {
        /// The day's cards, in the order they are asked.
        let entries: [Entry]
        /// Due cards the budget left for another day.
        let dueLeftOver: Int
        /// Eligible new cards not introduced today: over the allowance, or past
        /// the budget.
        let newLeftOver: Int
        /// New cards whose first graded attempt was made earlier today; items
        /// whose first graded attempt was their `.discovery` are not counted.
        let newIntroducedToday: Int

        static let empty = Today(entries: [], dueLeftOver: 0, newLeftOver: 0, newIntroducedToday: 0)

        var dueCount: Int { entries.reduce(0) { $0 + ($1.isNew ? 0 : 1) } }
        var newCount: Int { entries.reduce(0) { $0 + ($1.isNew ? 1 : 0) } }
        /// The day's list at the planning rates.
        var estimatedSeconds: Int {
            entries.reduce(0) { $0 + MemoryCardQueue.planningSeconds(isNew: $1.isNew) }
        }
    }

    static func planningSeconds(isNew: Bool) -> Int {
        isNew ? secondsPerNewCard : secondsPerDueCard
    }

    /// Whether an answer to a card now is written as an attempt: the card is
    /// active and due, or new and eligible (`dueAt` is a new card's first
    /// eligible moment). In practice the learner started, a new card counts
    /// even on the day it was kept, since its first answer sets its schedule;
    /// a card seen before still counts only when due. Every other answer is
    /// shown and not written.
    static func answerCounts(status: MemoryItemStatus, schedule: MemorySchedule, now: Date, practice: Bool) -> Bool {
        guard status == .active else { return false }
        return schedule.dueAt <= now || (practice && schedule.isNew)
    }

    /// Today's cards from the kept items and their whole attempt history.
    ///
    /// - Parameters:
    ///   - items: the items the caller may show: anchored on sources the
    ///     library has, outside any sync conflict. Retired items are skipped
    ///     here; an id that appears twice is taken once.
    ///   - attempts: every attempt on those items. Schedules are derived here,
    ///     so every surface derives the same ones.
    ///   - budgetMinutes: the day's minutes (`MemoryReviewBudget`, clamped
    ///     like everywhere else); nil leaves the list uncut.
    ///   - newPerDay: the day's allowance of new cards; below zero counts as zero.
    ///   - deadlines: notebooks with a block or Goal end; only those within
    ///     `deadlineHorizon` of `now`, and not yet past, count.
    ///   - calendar: the learner's day, for "kept before today" and "introduced
    ///     today".
    static func today(
        items: [MemoryItem],
        attempts: [MemoryAttempt],
        now: Date,
        budgetMinutes: Int?,
        newPerDay: Int,
        deadlines: [MemoryCardDeadline],
        calendar: Calendar = .current
    ) -> Today {
        let attemptsByItemID = Dictionary(grouping: attempts, by: \.memoryItemID)
        let startOfToday = calendar.startOfDay(for: now)
        let activeDeadlines = deadlines
            .filter { $0.at >= now && $0.at.timeIntervalSince(now) <= deadlineHorizon }
            .sorted {
                if $0.at != $1.at { return $0.at < $1.at }
                return $0.notebookID < $1.notebookID
            }

        var seen = Set<String>()
        var deadlineCards: [(entry: Entry, deadline: MemoryCardDeadline)] = []
        var dueCards: [Entry] = []
        var newCards: [Entry] = []
        var newIntroducedToday = 0

        for item in items.sorted(by: { $0.id < $1.id }) {
            guard item.status == .active, seen.insert(item.id).inserted else { continue }
            let itemAttempts = attemptsByItemID[item.id] ?? []
            let schedule = MemoryTutorScheduler.schedule(
                item: item,
                attempts: itemAttempts,
                calendar: calendar
            )
            if !schedule.isNew,
               let introduction = firstGradedAttempt(itemAttempts),
               introduction.attemptType != .discovery,
               introduction.attemptedAt >= startOfToday {
                newIntroducedToday += 1
            }
            // A new card's dueAt is its first eligible moment.
            guard schedule.dueAt <= now else { continue }
            let daysOverdue = schedule.isNew
                ? 0
                : Int(max(0, now.timeIntervalSince(schedule.dueAt)) / MemoryTutorScheduler.secondsPerDay)
            let anchorSourceIDs = Set(item.sources.map(\.sourceID))
            if let deadline = activeDeadlines.first(where: { deadline in
                item.goalID == deadline.notebookID || !deadline.sourceIDs.isDisjoint(with: anchorSourceIDs)
            }) {
                deadlineCards.append((
                    Entry(
                        item: item,
                        schedule: schedule,
                        bucket: .deadline,
                        notebookID: deadline.notebookID,
                        daysOverdue: daysOverdue
                    ),
                    deadline
                ))
            } else if schedule.isNew {
                newCards.append(Entry(
                    item: item,
                    schedule: schedule,
                    bucket: .new,
                    notebookID: nil,
                    daysOverdue: 0
                ))
            } else {
                dueCards.append(Entry(
                    item: item,
                    schedule: schedule,
                    bucket: .due,
                    notebookID: nil,
                    daysOverdue: daysOverdue
                ))
            }
        }

        let orderedDeadlineCards = deadlineCards
            .sorted { lhs, rhs in
                if lhs.deadline.at != rhs.deadline.at { return lhs.deadline.at < rhs.deadline.at }
                if lhs.deadline.notebookID != rhs.deadline.notebookID {
                    return lhs.deadline.notebookID < rhs.deadline.notebookID
                }
                if lhs.entry.isNew != rhs.entry.isNew { return !lhs.entry.isNew }
                return lhs.entry.isNew
                    ? isOlderKept(lhs.entry, rhs.entry)
                    : isMoreOverdue(lhs.entry, rhs.entry)
            }
            .map(\.entry)
        let deadlineNewCount = orderedDeadlineCards.reduce(0) { $0 + ($1.isNew ? 1 : 0) }
        let newAllowance = max(0, max(0, newPerDay) - newIntroducedToday - deadlineNewCount)
        let ordered = orderedDeadlineCards
            + dueCards.sorted(by: isMoreOverdue)
            + Array(newCards.sorted(by: isOlderKept).prefix(newAllowance))

        var entries: [Entry] = []
        if let budgetMinutes {
            let budgetSeconds = MemoryReviewBudget.clamp(budgetMinutes) * 60
            var spent = 0
            for entry in ordered {
                let cost = planningSeconds(isNew: entry.isNew)
                guard spent + cost <= budgetSeconds else { break }
                spent += cost
                entries.append(entry)
            }
        } else {
            entries = ordered
        }

        let eligibleDue = orderedDeadlineCards.count - deadlineNewCount + dueCards.count
        let eligibleNew = deadlineNewCount + newCards.count
        let takenNew = entries.reduce(0) { $0 + ($1.isNew ? 1 : 0) }
        return Today(
            entries: entries,
            dueLeftOver: eligibleDue - (entries.count - takenNew),
            newLeftOver: eligibleNew - takenNew,
            newIntroducedToday: newIntroducedToday
        )
    }

    /// The attempt that took the item out of "new": its earliest graded attempt
    /// with a rating, ties broken by id like the scheduler's order.
    private static func firstGradedAttempt(_ attempts: [MemoryAttempt]) -> MemoryAttempt? {
        attempts
            .filter { $0.gradeState == .graded && $0.scheduleRating != nil }
            .min {
                if $0.attemptedAt != $1.attemptedAt { return $0.attemptedAt < $1.attemptedAt }
                return $0.id < $1.id
            }
    }

    private static func isMoreOverdue(_ lhs: Entry, _ rhs: Entry) -> Bool {
        if lhs.schedule.dueAt != rhs.schedule.dueAt { return lhs.schedule.dueAt < rhs.schedule.dueAt }
        return lhs.item.id < rhs.item.id
    }

    private static func isOlderKept(_ lhs: Entry, _ rhs: Entry) -> Bool {
        if lhs.item.createdAt != rhs.item.createdAt { return lhs.item.createdAt < rhs.item.createdAt }
        return lhs.item.id < rhs.item.id
    }
}
