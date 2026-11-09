import Foundation
#if os(macOS)
@testable import ForeverLM
#endif

// The iPhone's card review and a notebook's Practice, the parts with no view
// and no CloudKit in them (docs/memory-design.md, "The card review on the
// iPhone"). The phone has no local database, so what the Mac's store reads
// and decides for a sitting (`KnowledgeStore.memoryCardReviewSnapshot`,
// `memoryCardNotebookPractice`, `recordSelfGradedMemoryCardAttempt`) is
// decided here over the synced items and attempts the phone holds, through
// the Mac's own pure rules: `MemoryCardDeal`, `MemoryCardScope`,
// `MemoryCardSitting`, `MemoryCardWording` and `MemoryCardQueue.answerCounts`.
// Foundation-only and compiled into the macOS unit tests beside
// `MobileNotebookModels.swift`, so each rule is pinned against the Mac's
// store (`MobileCardReviewTests`).

// MARK: - What a sitting reads

enum MobileCardReviewDealing {
    /// Today's cards in a scope, the new cards practice would take, and each
    /// dealt card's whole attempt history: the Mac's
    /// `memoryCardReviewSnapshot` for a sitting.
    struct Read: Equatable, Sendable {
        /// Today's cards, in the order they are asked (`MemoryCardDeal.today`).
        let today: MemoryCardQueue.Today
        /// The scope's new cards outside today's deal: kept today, or past
        /// the day's allowance (`MemoryCardDeal.practice`).
        let practice: [MemoryCardQueue.Entry]
        /// The whole history of each card in `today` and `practice`, by item.
        let attemptsByItemID: [String: [MemoryAttempt]]

        static let empty = Read(today: .empty, practice: [], attemptsByItemID: [:])

        /// "6 due · 4 new" and the practice count, as the Mac's Memory pane
        /// says them.
        var counts: MemoryCardDayCounts {
            MemoryCardDayCounts(today: today, practice: practice.count)
        }
    }

    /// A notebook's Practice on the phone: its kept cards, the ones whose
    /// answer is written (due, then new) apart from those not due yet
    /// (`MemoryCardDeal.notebookPractice`). Kept cards only: the phone's
    /// cards to check are gone through in To Check (`MobileCardsToCheckList`),
    /// so its Practice deals no draft.
    struct NotebookPractice: Equatable, Sendable {
        let kept: MemoryCardDeal.NotebookPractice
        let attemptsByItemID: [String: [MemoryAttempt]]

        static let empty = NotebookPractice(
            kept: MemoryCardDeal.NotebookPractice(answerable: [], notDueYet: []),
            attemptsByItemID: [:]
        )

        /// In the order they are dealt: the answers that count first.
        var entries: [MemoryCardQueue.Entry] { kept.all }
    }

    /// Only items with a face are cards (`MemoryCard.face`): an item the
    /// review cannot show is neither dealt nor counted, as on the Mac.
    static func cards(in items: [MemoryItem], attemptsByItemID: [String: [MemoryAttempt]]) -> [MemoryItem] {
        items.filter { MemoryCard.face(of: $0, attempts: attemptsByItemID[$0.id] ?? []) != nil }
    }

    /// Today's cards over `items` — the synced items the phone may show,
    /// anchored on its library's sources — in `scope` (every notebook when
    /// nil), with the day's minutes and new-card allowance, and no deadlines:
    /// the phone receives no calendar blocks or Goal end dates.
    static func read(
        items: [MemoryItem],
        attempts: [MemoryAttempt],
        now: Date,
        budgetMinutes: Int?,
        newPerDay: Int,
        scope: MemoryCardScope?,
        calendar: Calendar = .current
    ) -> Read {
        let attemptsByItemID = Dictionary(grouping: attempts, by: \.memoryItemID)
        let cards = cards(in: items, attemptsByItemID: attemptsByItemID)
        let today = MemoryCardDeal.today(
            items: cards,
            attempts: attempts,
            now: now,
            budgetMinutes: budgetMinutes,
            newPerDay: newPerDay,
            deadlines: [],
            scope: scope,
            calendar: calendar
        )
        let practice = MemoryCardDeal.practice(
            items: cards,
            attempts: attempts,
            scope: scope,
            excluding: Set(today.entries.map(\.id)),
            calendar: calendar
        )
        let dealt = Set(today.entries.map(\.id)).union(practice.map(\.id))
        return Read(
            today: today,
            practice: practice,
            attemptsByItemID: attemptsByItemID.filter { dealt.contains($0.key) }
        )
    }

    /// A notebook's Practice over `items` (`MemoryCardDeal.notebookPractice`).
    static func notebookPractice(
        items: [MemoryItem],
        attempts: [MemoryAttempt],
        scope: MemoryCardScope,
        now: Date,
        calendar: Calendar = .current
    ) -> NotebookPractice {
        let attemptsByItemID = Dictionary(grouping: attempts, by: \.memoryItemID)
        let kept = MemoryCardDeal.notebookPractice(
            items: cards(in: items, attemptsByItemID: attemptsByItemID),
            attempts: attempts,
            scope: scope,
            now: now,
            calendar: calendar
        )
        let dealt = Set(kept.all.map(\.id))
        return NotebookPractice(kept: kept, attemptsByItemID: attemptsByItemID.filter { dealt.contains($0.key) })
    }

    /// A notebook's Studio line on the phone, the Mac's `notebookCounts`:
    /// every kept card in the notebook (an active item with a face), and the
    /// due ones today's review in the notebook asks, the day's minutes
    /// included. Its cards to check are counted beside it, from the
    /// notebook's draft Cards (`currentNotebookCardCounts`).
    static func notebookCounts(
        items: [MemoryItem],
        attempts: [MemoryAttempt],
        scope: MemoryCardScope,
        now: Date,
        budgetMinutes: Int?,
        newPerDay: Int,
        calendar: Calendar = .current
    ) -> NotebookCardCounts {
        let attemptsByItemID = Dictionary(grouping: attempts, by: \.memoryItemID)
        var seen = Set<String>()
        let kept = cards(in: items, attemptsByItemID: attemptsByItemID).filter {
            $0.status == .active && scope.contains($0) && seen.insert($0.id).inserted
        }
        let today = read(
            items: items,
            attempts: attempts,
            now: now,
            budgetMinutes: budgetMinutes,
            newPerDay: newPerDay,
            scope: scope,
            calendar: calendar
        ).today
        return NotebookCardCounts(kept: kept.count, due: today.dueCount, toCheck: 0)
    }

    /// Queue entries as a sitting's cards, the Mac's `memorySittingCards`:
    /// each card's face in the wording its state row and its history give it
    /// (`MemoryCardWording.asked`: its front or the learner's rewording, a
    /// rewording in rotation once it has been remembered twice). A card whose
    /// row was not read is asked in its own words. An entry with no face is
    /// dropped.
    static func sittingCards(
        _ entries: [MemoryCardQueue.Entry],
        attemptsByItemID: [String: [MemoryAttempt]],
        states: [String: MemoryCardDeckState]
    ) -> [MemoryCardSitting.Card] {
        entries.compactMap { entry in
            MemoryCardSitting.Card.dealt(entry, attempts: attemptsByItemID[entry.id] ?? []) { face in
                face.stateDeckID(in: entry.item).flatMap { states[$0]?.cards[face.cardID] }
            }
        }
    }
}

// MARK: - Recording a self-graded answer

/// What one Forgot or Remembered writes on the phone: exactly what the Mac's
/// `KnowledgeStore.recordSelfGradedMemoryCardAttempt` would write, decided
/// from the card's history as this phone holds it, before the attempt goes to
/// CloudKit (`MobileMemoryAttemptRecorder.recordSelfGraded`).
///
/// - One answer per card per sitting: the attempt's id is derived from the
///   sitting's key and the card (`MemoryTutorIdentity.selfGradedAttemptID`),
///   so a "Review Forgotten" repeat, a retry or the same answer arriving from
///   another call is one record, and a second Forgot never halves the card's
///   stability again.
/// - Never for a retired card.
/// - Otherwise only when the card is due, or new and eligible, or new in
///   practice the learner started (`MemoryCardQueue.answerCounts`), so
///   practice never stretches an interval.
///
/// A written answer is `.graded`, its learner answer "(self-graded)", score 1
/// and `good` for Remembered, 0 and `again` for Forgot, with the wording
/// asked as its prompt and no session or exchange (`MemoryAttempt.selfGraded`).
enum MobileSelfGradedAnswer {
    enum Decision: Equatable, Sendable {
        /// Write this attempt.
        case write(MemoryAttempt)
        /// Write nothing: the Mac's outcome for an answer that is shown and
        /// keeps no trace.
        case skip(MemoryCardAnswerOutcome)
    }

    /// `history` is the card's item's attempts as this phone holds them (any
    /// other item's are ignored). Throws for an empty `sessionKey`, as the
    /// Mac's store does.
    static func decide(
        item: MemoryItem,
        history: [MemoryAttempt],
        prompt: String,
        remembered: Bool,
        sessionKey: String,
        practice: Bool,
        at now: Date,
        calendar: Calendar = .current
    ) throws -> Decision {
        guard !sessionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MobileCardReviewError.noSitting
        }
        let attemptID = MemoryTutorIdentity.selfGradedAttemptID(sessionKey: sessionKey, memoryItemID: item.id)
        let attempts = history.filter { $0.memoryItemID == item.id }
        if attempts.contains(where: { $0.id == attemptID }) { return .skip(.alreadyRecorded) }
        guard item.status == .active else { return .skip(.retired) }
        let schedule = MemoryTutorScheduler.schedule(item: item, attempts: attempts, calendar: calendar)
        guard MemoryCardQueue.answerCounts(status: item.status, schedule: schedule, now: now, practice: practice) else {
            return .skip(.notCounted)
        }
        return .write(.selfGraded(
            id: attemptID,
            memoryItemID: item.id,
            prompt: prompt,
            remembered: remembered,
            at: now
        ))
    }
}

enum MobileCardReviewError: LocalizedError, Equatable {
    /// An answer with no sitting to count it in.
    case noSitting
    /// The card's item is no longer on this iPhone.
    case cardGone

    var errorDescription: String? {
        switch self {
        case .noSitting: return "A self-graded answer needs the sitting it was given in."
        case .cardGone: return "This card is no longer on this iPhone."
        }
    }
}

// MARK: - The screen's words and scope

enum MobileCardReviewCopy {
    /// What the scope control calls `scope`: "All notebooks", or the
    /// notebook's name ("Notebook" when it has none).
    static func scopeTitle(_ scope: MemoryReviewScope, notebooks: [MobileCloudNotebook]) -> String {
        switch scope {
        case .allNotebooks:
            return "All notebooks"
        case .notebook(let id):
            let title = notebooks.first { $0.id == id }?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return title.isEmpty ? "Notebook" : title
        }
    }

    /// `scope`, or every notebook when it names a notebook this phone no
    /// longer holds (an archived one still counts: its cards are still
    /// asked), the Mac's `validMemoryReviewScope`.
    static func validScope(_ scope: MemoryReviewScope, notebookIDs: Set<String>) -> MemoryReviewScope {
        guard case .notebook(let id) = scope else { return scope }
        return notebookIDs.contains(id) ? scope : .allNotebooks
    }

    /// "18 cards · 12 remembered · 6 forgot", the end of a round.
    static func roundSummary(cardCount: Int, remembered: Int, forgot: Int) -> String {
        let cards = cardCount == 1 ? "1 card" : "\(cardCount) cards"
        return "\(cards) · \(remembered) remembered · \(forgot) forgot"
    }

    /// The empty review's offer of the new cards today's deal leaves out.
    static func practiceNewCards(_ count: Int) -> String {
        count == 1 ? "Practice 1 New Card" : "Practice \(count) New Cards"
    }

    /// A notebook's Studio Cards row on the phone: "42 kept · 6 due · 9 to
    /// check", or that it has none yet.
    static func studioLine(_ counts: NotebookCardCounts?) -> String {
        guard let counts else { return "Counting…" }
        return counts.line ?? "No cards kept yet"
    }
}

// MARK: - The Memory screen

// The iPhone's Memory screen (docs/memory-design.md, "The Memory screen on
// the iPhone"), the parts with no view: the Mac's Memory pane's Review and
// All Cards over every notebook, read from what the phone holds.

extension MobileCardReviewDealing {
    /// The notebooks among `scopes` that hold a kept card (active, with a
    /// face to show) in `items`.
    static func notebookIDsWithCards(items: [MemoryItem], attempts: [MemoryAttempt], scopes: [MemoryCardScope]) -> Set<String> {
        let attemptsByItemID = Dictionary(grouping: attempts, by: \.memoryItemID)
        let kept = cards(in: items, attemptsByItemID: attemptsByItemID).filter { $0.status == .active }
        return Set(scopes.filter { scope in kept.contains(where: scope.contains) }.map(\.notebookID))
    }

    /// Every kept card over `items` — active, with a face to show — oldest
    /// kept first: the Mac's `memoryCardReviewSnapshot` listings over every
    /// notebook, which the Memory screen's All Cards lists.
    static func listings(items: [MemoryItem], attempts: [MemoryAttempt], calendar: Calendar = .current) -> [MemoryCardListing] {
        let attemptsByItemID = Dictionary(grouping: attempts, by: \.memoryItemID)
        var seen = Set<String>()
        return cards(in: items, attemptsByItemID: attemptsByItemID)
            .filter { $0.status == .active && seen.insert($0.id).inserted }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id < $1.id
            }
            .compactMap { MemoryCardListing(item: $0, attempts: attemptsByItemID[$0.id] ?? [], calendar: calendar) }
    }
}

/// The Memory screen's words, the Mac's Memory pane's.
enum MobileMemoryScreenCopy {
    /// What the card on Review's deck says under how many cards wait today:
    /// the Mac's `MemoryPane.todayDeck`, "cards today" ("6 due · 4 new"
    /// under it is `MemoryCardDayCounts.todayLine`).
    static func deckCaption(today: Int) -> String {
        today == 1 ? "card today" : "cards today"
    }

    /// What the card on the deck says when no card waits today: that today's
    /// review is done, or that nothing is due.
    static func emptyDeckTitle(state: MemoryReviewCommitment.State) -> String {
        if case .done = state { return "Today's review is done" }
        return "Nothing due today"
    }

    /// Whether the promise line shows under the deck, the Mac's
    /// `MemoryPane.showsPromise`: on an open or done day only while cards
    /// wait, so a done deck is never followed by a second "done".
    static func showsPromise(state: MemoryReviewCommitment.State, counts: MemoryCardDayCounts) -> Bool {
        switch state {
        case .open, .done: return counts.today > 0
        case .ended: return true
        }
    }

    /// Where today's review stands on the phone: done once the day's goal is
    /// met on any device, open otherwise (`MemoryReviewCommitment.state`).
    /// The phone makes no commitment — it writes and reads no end record, and
    /// its card review records no day done by its cards — so it never holds
    /// a day ended early.
    static func state(goal: MemoryReviewGoalSnapshot) -> MemoryReviewCommitment.State {
        MemoryReviewCommitment.state(snapshot: goal, end: nil)
    }

    /// The primary button, the Mac's `MemoryPane.primaryTitle`: Start Review
    /// while the day is open and a card waits, Keep Going on a done day with
    /// cards left, nothing on a day ended early or with no card waiting.
    static func primaryTitle(state: MemoryReviewCommitment.State, counts: MemoryCardDayCounts) -> String? {
        guard counts.today > 0 else { return nil }
        switch state {
        case .open: return "Start Review"
        case .done, .ended: return "Keep Going"
        }
    }

    /// The sentence under the deck. A done day says what the Mac's Memory
    /// pane says, one line since 2026-10-06. An open day says nothing: the
    /// Mac's promise there — the day's minutes, and that leaving early ends
    /// today's review — is its committed session, which the phone does not
    /// hold.
    static func promise(state: MemoryReviewCommitment.State) -> String? {
        guard case .done = state else { return nil }
        return "Today's review is done."
    }

    /// "New", "Due", "Tomorrow", or the day a card is next asked: what All
    /// Cards says beside a card, the Mac's `MemoryPane.statusLine`.
    static func statusLine(_ schedule: MemorySchedule, now: Date = Date(), calendar: Calendar = .current) -> String {
        if schedule.isNew { return "New" }
        if schedule.dueAt <= now { return "Due" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(schedule.dueAt, inSameDayAs: tomorrow) {
            return "Tomorrow"
        }
        return schedule.dueAt.formatted(.dateTime.month(.abbreviated).day())
    }

    /// What a day's square says when it is picked, and what VoiceOver reads:
    /// the date, and what happened on it, the Mac's
    /// `MemoryReviewHistoryGrid.dayDescription`. No count of days.
    static func dayDescription(_ day: MemoryReviewHistory.Day, calendar: Calendar = .current) -> String {
        let date = MemoryReviewSession.title(for: day.date, calendar: calendar)
        let today = day.isToday ? " · today" : ""
        guard day.level != .none else { return date + today }
        let minutes = Int((day.activeSeconds / 60).rounded())
        return minutes >= 1 ? "\(date) · \(minutes) min\(today)" : "\(date) · review\(today)"
    }
}

/// The review chats the Memory screen's history grid reads beside the
/// synced minutes (`MemoryReviewHistory.grid`), from the review sessions the
/// phone holds — the Mac's rail Memory group and `answeredMemoryReviewDays`.
enum MobileMemoryHistoryDays {
    /// One day-named review chat as the phone holds it.
    struct Session: Equatable, Sendable {
        let id: String
        /// Whether its transcript holds any turn; an empty one has nothing
        /// to open.
        let hasTurns: Bool
        /// Whether the learner wrote in it: an exchange with an answer of
        /// theirs. A chat the morning prepared and nobody sat is not.
        let isAnswered: Bool
        /// Hidden on a Mac, as the rail leaves it out.
        let isHidden: Bool
    }

    struct Days: Equatable, Sendable {
        /// The days before today with a review chat to open.
        let chatDays: Set<String>
        /// The days whose chat the learner wrote in, today's included: what
        /// colours a day with no minutes.
        let answeredDays: Set<String>

        static let none = Days(chatDays: [], answeredDays: [])
    }

    /// Today's chat is not one of the days to open — Start Review is the way
    /// into today, and the card review's ⋯ continues today's chat — but an
    /// answer in it still colours today.
    static func days(of sessions: [Session], now: Date, calendar: Calendar = .current) -> Days {
        let today = MemoryReviewGoal.dayKey(for: now, calendar: calendar)
        var chatDays = Set<String>()
        var answeredDays = Set<String>()
        for session in sessions {
            guard let day = MemoryReviewSession.dayKey(fromSessionID: session.id) else { continue }
            if session.isAnswered { answeredDays.insert(day) }
            if session.hasTurns, !session.isHidden, day != today { chatDays.insert(day) }
        }
        return Days(chatDays: chatDays, answeredDays: answeredDays)
    }

    /// The session id a day's square opens.
    static func sessionID(day: String) -> String {
        MemoryReviewSession.idPrefix + day
    }
}

/// How the history grid fits a phone: half a year of columns across, each
/// square as large as the width allows between the smallest legible one and
/// an iPad's, and fewer weeks only where even the smallest squares cannot
/// fit half a year (a narrow iPad split).
enum MobileMemoryHistoryLayout {
    static let spacing: Double = 3
    /// The weekday letters beside the first column, and the gap after them.
    static let gutterWidth: Double = 12
    static let gutterGap: Double = 6
    static let smallestCell: Double = 8
    static let largestCell: Double = 16

    /// The columns `width` points hold, at most `MemoryReviewHistory.defaultWeeks`.
    static func weeks(width: Double, preferred: Int = MemoryReviewHistory.defaultWeeks) -> Int {
        let room = width - gutterWidth - gutterGap + spacing
        let fit = Int((room / (smallestCell + spacing)).rounded(.down))
        return max(1, min(preferred, fit))
    }

    /// The square for `weeks` columns in `width` points, in whole points.
    static func cellSize(width: Double, weeks: Int) -> Double {
        let columns = Double(max(1, weeks))
        let room = width - gutterWidth - gutterGap - (columns - 1) * spacing
        return min(largestCell, max(smallestCell, (room / columns).rounded(.down)))
    }
}
