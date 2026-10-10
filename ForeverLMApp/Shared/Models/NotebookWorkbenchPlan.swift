import Foundation

/// Derived, glanceable numbers for a Learning Companion goal's daily quiz card.
/// Pure function of the goal record — mirrors the `daily_quiz` MCP blend so the
/// in-app Today panel and the assistant show the same plan.
struct CompanionCardPlan {
    let daysRemaining: Int
    let progress: Double
    let completed: Int
    let approvedTotal: Int
    let newToday: Int
    let reviewToday: Int
    let openGaps: Int
    let pending: Int
    let endDateText: String
    let todaysItems: [(item: LearningGoalItem, isReview: Bool)]

    init(goal: LearningGoalRecord) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let endDay = cal.startOfDay(for: goal.endAt)
        let dayDiff = cal.dateComponents([.day], from: today, to: endDay).day ?? 0
        let pacingDays = max(1, dayDiff + 1)
        // The count the Goals tab and the Planner's Toward rail draw, not the
        // pacing divisor: 0 on the day the Goal falls due.
        daysRemaining = goal.daysRemaining(asOf: today, calendar: cal).map { max(0, $0) } ?? 0

        let approvedOpen = goal.items.filter { $0.isApproved && !$0.isCompleted }
        let newRemaining = approvedOpen.filter { ($0.quizCount ?? 0) == 0 }
        let reviewPool = approvedOpen.filter { ($0.quizCount ?? 0) > 0 }
        let target = max(1, goal.dailyTarget ?? 3)
        let newPerDayNeeded = newRemaining.isEmpty ? 0 : Int(ceil(Double(newRemaining.count) / Double(pacingDays)))
        var nt = min(newRemaining.count, max(newRemaining.isEmpty ? 0 : 1, newPerDayNeeded))
        nt = min(nt, target)
        newToday = nt
        let rt = min(reviewPool.count, max(0, target - nt))
        reviewToday = rt

        let newSorted = newRemaining.sorted { a, b in
            // User-sequenced sources come first, in the chosen study order.
            if a.sequence != b.sequence {
                guard let aSeq = a.sequence else { return false }
                guard let bSeq = b.sequence else { return true }
                return aSeq < bSeq
            }
            let aSeed = a.origin == LearningGoalItemOrigin.seed.rawValue
            let bSeed = b.origin == LearningGoalItemOrigin.seed.rawValue
            if aSeed != bSeed { return aSeed }
            let ar = a.relevance ?? 0, br = b.relevance ?? 0
            if ar != br { return ar > br }
            return a.addedAt < b.addedAt
        }
        let reviewSorted = reviewPool.sorted { a, b in
            let asc = a.lastScore ?? 0, bsc = b.lastScore ?? 0
            if asc != bsc { return asc < bsc }
            return (a.lastQuizzedAt ?? .distantPast) < (b.lastQuizzedAt ?? .distantPast)
        }
        todaysItems = newSorted.prefix(nt).map { (item: $0, isReview: false) }
            + reviewSorted.prefix(rt).map { (item: $0, isReview: true) }

        let approvedAll = goal.items.filter { $0.isApproved }
        approvedTotal = approvedAll.count
        completed = approvedAll.filter { $0.isCompleted }.count
        progress = approvedTotal == 0 ? 0 : Double(completed) / Double(approvedTotal)
        openGaps = (goal.gaps ?? []).filter { $0.isOpen }.count
        pending = goal.items.filter { $0.isPendingApproval }.count

        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        endDateText = fmt.string(from: goal.endAt)
    }
}

/// Pure, glanceable research state for the in-app Notebook workbench.
/// Mirrors enriched MCP notebook context without blocking the main actor.
struct NotebookWorkbenchPlan {
    struct NextSuggestion: Equatable {
        let sourceIDs: [String]
        let reason: String
        let tiedQuestionID: String?
    }

    let next: NextSuggestion?
    let openQuestions: [LearningGoalGap]
    let pendingSuggestions: [LearningGoalItem]
    let toRead: [LearningGoalItem]
    let reading: [LearningGoalItem]
    let understood: [LearningGoalItem]
    let reviewDueSourceIDs: Set<String>
    let masteredCount: Int
    let approvedCount: Int

    init(goal: LearningGoalRecord, reviewDueSourceIDs: Set<String> = []) {
        let approved = goal.items.filter(\.isApproved)
        openQuestions = (goal.gaps ?? [])
            .filter(\.isOpen)
            .sorted { ($0.severity ?? 0) > ($1.severity ?? 0) }
        pendingSuggestions = goal.items.filter(\.isPendingApproval)
        toRead = approved.filter { $0.derivedUnderstandingState == .toRead }
        reading = approved.filter { $0.derivedUnderstandingState == .reading }
        understood = approved.filter { $0.derivedUnderstandingState == .understood }
        self.reviewDueSourceIDs = reviewDueSourceIDs
        masteredCount = understood.count
        approvedCount = approved.count
        next = Self.nextSuggestion(
            goal: goal,
            approved: approved,
            openQuestions: openQuestions,
            reviewDueSourceIDs: reviewDueSourceIDs
        )
    }

    private static func nextSuggestion(
        goal: LearningGoalRecord,
        approved: [LearningGoalItem],
        openQuestions: [LearningGoalGap],
        reviewDueSourceIDs: Set<String>
    ) -> NextSuggestion? {
        let approvedByID = Dictionary(uniqueKeysWithValues: approved.map { ($0.sourceID, $0) })
        let readingItems = approved.filter { $0.derivedUnderstandingState == .reading }
        let toReadItems = approved.filter { $0.derivedUnderstandingState == .toRead }

        if let gap = openQuestions.first(where: { $0.sourceID != nil }),
           let sourceID = gap.sourceID,
           let item = approvedByID[sourceID],
           item.derivedUnderstandingState != .understood {
            return NextSuggestion(
                sourceIDs: [sourceID],
                reason: gap.summary,
                tiedQuestionID: gap.id
            )
        }

        if let dueItem = approved.first(where: { reviewDueSourceIDs.contains($0.sourceID) }) {
            return NextSuggestion(
                sourceIDs: [dueItem.sourceID],
                reason: "Spaced review is due for this source.",
                tiedQuestionID: nil
            )
        }

        if let gap = openQuestions.first,
           let item = readingItems.first ?? toReadItems.first {
            return NextSuggestion(
                sourceIDs: [item.sourceID],
                reason: gap.summary,
                tiedQuestionID: gap.id
            )
        }

        if let item = readingItems.first ?? toReadItems.first {
            return NextSuggestion(
                sourceIDs: [item.sourceID],
                reason: "Continue with the next source in your pool.",
                tiedQuestionID: nil
            )
        }

        if approved.isEmpty, !goal.items.filter(\.isPendingApproval).isEmpty {
            return nil
        }

        return nil
    }
}

// MARK: - Daily review (chat-first)

enum DailyReviewItemRole: String, Codable, Equatable {
    case gap
    case memory
    case new
    case review
    case continueReading
    case interest
}

struct DailyReviewPlanItem: Equatable {
    let sourceID: String
    let role: DailyReviewItemRole
}

/// Deterministic daily review payload for in-app Review Chat and MCP `daily_review`.
/// Merges open gaps, spaced repetition, companion pacing, in-progress reading, and
/// topic relevance — without writing to `scheduled_sources`.
struct DailyReviewPlan: Equatable {
    let goalID: String
    let sourceIDs: [String]
    let items: [DailyReviewPlanItem]
    let topic: String
    let rationale: String
    let doneToday: Bool

    static func assemble(
        goal: LearningGoalRecord,
        memoryDue: [MemoryReviewDueItem],
        readingInProgressSourceIDs: Set<String>,
        now: Date = Date()
    ) -> DailyReviewPlan? {
        let approved = goal.items.filter { $0.isApproved && !$0.isCompleted }
        guard !approved.isEmpty else { return nil }

        let target = max(1, goal.dailyTarget ?? 3)
        var selected: [DailyReviewPlanItem] = []
        var seen = Set<String>()

        func add(_ sourceID: String, _ role: DailyReviewItemRole) {
            guard seen.insert(sourceID).inserted, selected.count < target else { return }
            selected.append(DailyReviewPlanItem(sourceID: sourceID, role: role))
        }

        let approvedByID = Dictionary(uniqueKeysWithValues: approved.map { ($0.sourceID, $0) })
        let openGaps = (goal.gaps ?? [])
            .filter(\.isOpen)
            .sorted { ($0.severity ?? 0) > ($1.severity ?? 0) }

        for gap in openGaps {
            if let sourceID = gap.sourceID, approvedByID[sourceID] != nil {
                add(sourceID, .gap)
            }
        }

        for due in memoryDue {
            if approvedByID[due.sourceID] != nil {
                add(due.sourceID, .memory)
            }
        }

        let cardPlan = CompanionCardPlan(goal: goal)
        for entry in cardPlan.todaysItems {
            add(entry.item.sourceID, entry.isReview ? .review : .new)
        }

        let continueReading = approved.filter { item in
            readingInProgressSourceIDs.contains(item.sourceID) && (item.quizCount ?? 0) == 0
        }
        for item in continueReading {
            add(item.sourceID, .continueReading)
        }

        let byRelevance = approved.sorted { ($0.relevance ?? 0) > ($1.relevance ?? 0) }
        for item in byRelevance {
            add(item.sourceID, .interest)
        }

        guard !selected.isEmpty else { return nil }

        let calendar = Calendar.current
        let todayISO = isoDateOnly(now, calendar: calendar)
        let doneToday = goal.lastQuizDate == todayISO

        return DailyReviewPlan(
            goalID: goal.id,
            sourceIDs: selected.map(\.sourceID),
            items: selected,
            topic: goal.topic ?? goal.title,
            rationale: buildRationale(
                goal: goal,
                items: selected,
                openGaps: openGaps,
                memoryDue: memoryDue
            ),
            doneToday: doneToday
        )
    }

    private static func isoDateOnly(_ date: Date, calendar: Calendar) -> String {
        let fmt = DateFormatter()
        fmt.calendar = calendar
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }

    private static func buildRationale(
        goal: LearningGoalRecord,
        items: [DailyReviewPlanItem],
        openGaps: [LearningGoalGap],
        memoryDue: [MemoryReviewDueItem]
    ) -> String {
        var parts: [String] = []
        let topic = goal.topic ?? goal.title
        parts.append("Today's focus for \(topic):")

        if items.contains(where: { $0.role == .gap }),
           let gap = openGaps.first(where: { $0.sourceID != nil }) {
            parts.append("Revisit an open question (\(gap.summary)).")
        }
        if items.contains(where: { $0.role == .memory }) {
            let overdue = memoryDue.first?.daysOverdue ?? 0
            if overdue > 0 {
                parts.append("Refresh material due for spaced repetition (\(overdue) day\(overdue == 1 ? "" : "s") overdue).")
            } else {
                parts.append("Refresh material due for spaced repetition.")
            }
        }
        if items.contains(where: { $0.role == .new }) {
            parts.append("Cover new approved sources to stay on pace.")
        }
        if items.contains(where: { $0.role == .review }) {
            parts.append("Re-quiz weaker prior material.")
        }
        if items.contains(where: { $0.role == .continueReading }) {
            parts.append("Follow up on sources you were recently reading.")
        }

        return parts.joined(separator: " ")
    }
}

// MARK: - Daily memory companion

/// Why a target is in today's memory conversation. This is scheduling state,
/// not learner-facing flashcard metadata: the tutor still generates a fresh
/// question from the target and its source evidence on every attempt.
enum MemoryCompanionReason: String, Codable, Equatable, Sendable {
    case struggle
    case due
    case firstReview = "first_review"
}

/// One ordered target in the morning memory conversation. Existing memories
/// carry their durable item. A first review deliberately carries only a source
/// ID: the tutor must observe a real learner attempt before it can author and
/// persist a grounded memory item.
struct MemoryCompanionTarget: Equatable, Sendable, Identifiable {
    let memoryItem: MemoryItem?
    let sourceID: String
    let reason: MemoryCompanionReason
    let daysOverdue: Int

    var id: String {
        memoryItem?.id ?? "first-review:\(sourceID)"
    }

    var memoryItemID: String? { memoryItem?.id }
}

/// A small, deterministic review queue shared by Review Chat and the MCP
/// briefing. It contains learning targets and rubrics, never static prompts or
/// answers; the visible exchange stays conversational and is persisted only in
/// the review transcript and immutable attempt evidence.
struct MemoryCompanionPlan: Equatable, Sendable {
    let targets: [MemoryCompanionTarget]
    let topic: String
    let goalID: String?
    let generatedAt: Date

    var sourceIDs: [String] {
        var seen = Set<String>()
        return targets.flatMap { target in
            let ids = target.memoryItem?.sources.map(\.sourceID) ?? [target.sourceID]
            return ids.filter { seen.insert($0).inserted }
        }
    }

    var memoryItemIDs: [String] {
        targets.compactMap(\.memoryItemID)
    }

    var isEmpty: Bool { targets.isEmpty }

    static func assemble(
        dueItems: [DueMemoryItem],
        firstReviews: [MemoryReviewNewItem],
        availableSourceIDs: Set<String>,
        recentSourceActivity: [MemoryTutorRecentSourceActivity] = [],
        goalID: String? = nil,
        topic: String = "Daily memory check",
        limit: Int = 5,
        now: Date = Date()
    ) -> MemoryCompanionPlan? {
        let selection = MemoryTutorQueueSelection.select(
            dueItems: dueItems,
            firstReviews: firstReviews,
            availableSourceIDs: availableSourceIDs,
            recentSourceActivity: recentSourceActivity,
            limit: limit
        )
        var targets = selection.dueItems.compactMap { due -> MemoryCompanionTarget? in
            guard let sourceID = due.item.sources
                .map(\.sourceID)
                .first(where: availableSourceIDs.contains) else { return nil }
            return MemoryCompanionTarget(
                memoryItem: due.item,
                sourceID: sourceID,
                reason: MemoryTutorQueueSelection.isStruggle(due) ? .struggle : .due,
                daysOverdue: due.daysOverdue
            )
        }
        targets.append(contentsOf: selection.firstReviews.map { item in
            MemoryCompanionTarget(
                memoryItem: nil,
                sourceID: item.sourceID,
                reason: .firstReview,
                daysOverdue: item.daysOverdue
            )
        })

        let targetByID = Dictionary(
            uniqueKeysWithValues: targets.map { target in
                let id = target.memoryItemID
                    ?? MemoryTutorQueueIdentity.firstReview(sourceID: target.sourceID)
                return (id, target)
            }
        )
        targets = selection.orderedIDs.compactMap { targetByID[$0] }

        guard !targets.isEmpty else { return nil }
        return MemoryCompanionPlan(
            targets: targets,
            topic: topic,
            goalID: goalID,
            generatedAt: now
        )
    }

}

/// Typed handoff into Review Chat. Ordinary Notebook reviews leave `memoryPlan`
/// nil and retain their existing source-level behavior; the morning companion
/// supplies a plan and activates strict turn-level memory recording.
struct MemoryCompanionRequest: Equatable, Sendable {
    let goalID: String?
    let sourceIDs: [String]
    let topic: String
    let rationale: String?
    let memoryPlan: MemoryCompanionPlan?
}
