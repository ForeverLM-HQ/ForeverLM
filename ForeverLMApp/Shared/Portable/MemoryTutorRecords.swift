#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - Durable memory tutor records
//
// The records every memory surface shares, and the pure schedule projection
// over them. Portable since the card review: `MemoryCardQueue` (beside this
// file) deals today's cards from these types on the Mac, the iPhone and the
// website's WebAssembly core alike, so they carry no app services and import
// nothing past Foundation. The rest of the memory tutor's models stay in
// `Shared/Models/MemoryTutorModels.swift`.

/// The learning shape being practiced. Identity is supplied by the caller and is
/// never inferred by an LLM; model output may describe a target, but cannot decide
/// which durable record it belongs to.
enum MemoryItemKind: String, Codable, CaseIterable, Sendable {
    case concept
    case procedure
    case relationship
    case application
}

enum MemoryItemStatus: String, Codable, CaseIterable, Sendable {
    case active
    case retired
}

/// Why an immutable attempt was created. Discovery attempts establish an initial
/// signal; review attempts advance an existing memory; imported attempts preserve
/// a review completed in another client.
enum MemoryAttemptType: String, Codable, CaseIterable, Sendable {
    case review
    case discovery
    case imported
}

/// A small, provider-independent result that the local scheduler understands.
/// The tutor must supply this explicitly after successful grading; storage never
/// guesses a rating from prose or a numeric score.
enum MemoryScheduleRating: String, Codable, CaseIterable, Sendable {
    case again
    case hard
    case good
    case easy
}

enum MemoryGradeState: String, Codable, CaseIterable, Sendable {
    case pending
    case graded
    case failed
}

/// A source-grounded anchor for one memory item. The source hash binds the excerpt
/// and locator to the exact source revision the learner originally encountered.
struct MemoryItemSource: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let memoryItemID: String
    let sourceID: String
    let locatorJSON: String?
    let excerpt: String
    let sourceSHA256: String
    let sortIndex: Int

    init(
        id: String,
        memoryItemID: String,
        sourceID: String,
        locatorJSON: String? = nil,
        excerpt: String,
        sourceSHA256: String,
        sortIndex: Int
    ) {
        self.id = id
        self.memoryItemID = memoryItemID
        self.sourceID = sourceID
        self.locatorJSON = locatorJSON
        self.excerpt = excerpt
        self.sourceSHA256 = sourceSHA256
        self.sortIndex = sortIndex
    }
}

/// A dynamic learning target, rather than a static question/answer flashcard.
/// Prompts are generated at review time from the target, rubric, learner context,
/// and source anchors.
struct MemoryItem: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let kind: MemoryItemKind
    let target: String
    let rubricJSON: String
    let learnerContext: String?
    let goalID: String?
    let status: MemoryItemStatus
    let sources: [MemoryItemSource]
    let createdAt: Date
    let updatedAt: Date
    /// The idea this item is a weak spot of (schema 89). A target made by the
    /// memory review always carries one; items the external assistant created
    /// before ideas existed have none.
    let ideaID: String?

    init(
        id: String,
        kind: MemoryItemKind,
        target: String,
        rubricJSON: String,
        learnerContext: String? = nil,
        goalID: String? = nil,
        status: MemoryItemStatus = .active,
        sources: [MemoryItemSource],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        ideaID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.target = target
        self.rubricJSON = rubricJSON
        self.learnerContext = learnerContext
        self.goalID = goalID
        self.status = status
        self.sources = sources
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.ideaID = ideaID
    }

    func replacingSources(_ sources: [MemoryItemSource]) -> MemoryItem {
        MemoryItem(
            id: id,
            kind: kind,
            target: target,
            rubricJSON: rubricJSON,
            learnerContext: learnerContext,
            goalID: goalID,
            status: status,
            sources: sources,
            createdAt: createdAt,
            updatedAt: updatedAt,
            ideaID: ideaID
        )
    }
}

/// One immutable learner interaction. A failed grader is recorded as a failed
/// attempt and never disguised as a heuristic grade. Only `.graded` attempts with
/// an explicit schedule rating advance the local schedule projection.
struct MemoryAttempt: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let memoryItemID: String
    let sessionID: String?
    let exchangeID: String?
    let attemptType: MemoryAttemptType
    let prompt: String
    let learnerAnswer: String
    let feedback: String?
    let score: Double?
    let scheduleRating: MemoryScheduleRating?
    let gradeState: MemoryGradeState
    let gradingError: String?
    let evidenceJSON: String?
    let attemptedAt: Date
    let modelProvider: String?
    let modelID: String?
    let modelMetadataJSON: String?

    init(
        id: String,
        memoryItemID: String,
        sessionID: String? = nil,
        exchangeID: String? = nil,
        attemptType: MemoryAttemptType = .review,
        prompt: String,
        learnerAnswer: String,
        feedback: String? = nil,
        score: Double? = nil,
        scheduleRating: MemoryScheduleRating? = nil,
        gradeState: MemoryGradeState,
        gradingError: String? = nil,
        evidenceJSON: String? = nil,
        attemptedAt: Date = Date(),
        modelProvider: String? = nil,
        modelID: String? = nil,
        modelMetadataJSON: String? = nil
    ) {
        self.id = id
        self.memoryItemID = memoryItemID
        self.sessionID = sessionID
        self.exchangeID = exchangeID
        self.attemptType = attemptType
        self.prompt = prompt
        self.learnerAnswer = learnerAnswer
        self.feedback = feedback
        self.score = score
        self.scheduleRating = scheduleRating
        self.gradeState = gradeState
        self.gradingError = gradingError
        self.evidenceJSON = evidenceJSON
        self.attemptedAt = attemptedAt
        self.modelProvider = modelProvider
        self.modelID = modelID
        self.modelMetadataJSON = modelMetadataJSON
    }

    func linked(sessionID: String, exchangeID: String) -> MemoryAttempt {
        MemoryAttempt(
            id: id,
            memoryItemID: memoryItemID,
            sessionID: sessionID,
            exchangeID: exchangeID,
            attemptType: attemptType,
            prompt: prompt,
            learnerAnswer: learnerAnswer,
            feedback: feedback,
            score: score,
            scheduleRating: scheduleRating,
            gradeState: gradeState,
            gradingError: gradingError,
            evidenceJSON: evidenceJSON,
            attemptedAt: attemptedAt,
            modelProvider: modelProvider,
            modelID: modelID,
            modelMetadataJSON: modelMetadataJSON
        )
    }
}

/// Local, regenerable projection of immutable attempts. This record is never sent
/// to CloudKit; each device derives it deterministically from the same item and
/// attempt history.
struct MemorySchedule: Codable, Equatable, Sendable, Identifiable {
    let memoryItemID: String
    let dueAt: Date
    let lastAttemptAt: Date?
    let lastSuccessAt: Date?
    let stability: Double
    let difficulty: Double
    let repetitionCount: Int
    let lapseCount: Int
    let algorithmVersion: Int

    var id: String { memoryItemID }

    /// No graded attempt has reached this item yet. A new item is never due:
    /// `dueAt` is the moment it becomes eligible (the start of the local day
    /// after it was kept), and the daily queue introduces a capped number of
    /// eligible new items a day (`MemoryCardQueue`).
    var isNew: Bool { repetitionCount == 0 }

    init(
        memoryItemID: String,
        dueAt: Date,
        lastAttemptAt: Date? = nil,
        lastSuccessAt: Date? = nil,
        stability: Double = 0,
        difficulty: Double = 0.5,
        repetitionCount: Int = 0,
        lapseCount: Int = 0,
        algorithmVersion: Int = MemoryTutorScheduler.algorithmVersion
    ) {
        self.memoryItemID = memoryItemID
        self.dueAt = dueAt
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessAt = lastSuccessAt
        self.stability = stability
        self.difficulty = difficulty
        self.repetitionCount = repetitionCount
        self.lapseCount = lapseCount
        self.algorithmVersion = algorithmVersion
    }
}

// MARK: - Pure schedule projection

/// A deliberately small, transparent scheduler. It consumes only durable values,
/// uses no wall clock internally, and breaks ties by stable IDs so Mac and iPhone
/// derive the same plan from the same event history. The one input outside that
/// history is the calendar the learner's day is counted in, which places a new
/// item's first eligible moment.
///
/// Version 2, for cards:
/// - An item no graded attempt has reached yet is **new**. It is never due. It
///   becomes eligible at the start of the local day after it was kept ("no quiz
///   on the day of consumption"), and `MemoryCardQueue` introduces at most the
///   day's allowance of eligible new items. Its first graded attempt sets the
///   schedule, whenever it comes, so learner-started practice of a card kept
///   today counts as its first review.
/// - A success before the item is due does not stretch its interval. Practice,
///   a repeat inside one review and an early answer elsewhere count as a review
///   and a success, but stability, difficulty and the due date stay where the
///   last on-time review put them. A miss always counts.
/// - An answer given on the item's first local day (the day it was kept or
///   missed) never makes it due that same day: its due date is at least the
///   start of the next local day. A walkthrough Forgot at 09:00 would otherwise
///   be due at 21:00, a quiz on the day of consumption.
///
/// The projection never syncs. The Mac keeps it in `memory_schedules` tagged with
/// `algorithmVersion` and rebuilds rows an older version wrote at `.utility`
/// after launch (`KnowledgeStore.rebuildStaleMemorySchedules`); the iPhone
/// derives it on every read.
enum MemoryTutorScheduler {
    static let algorithmVersion = 2
    static let secondsPerDay: TimeInterval = 86_400
    static let minimumStabilityDays = 0.5
    static let maximumStabilityDays: Double = 365

    /// When an item kept at `createdAt` may first be asked: the start of the
    /// next day in `calendar`.
    static func firstEligibleAt(createdAt: Date, calendar: Calendar = .current) -> Date {
        let startOfDay = calendar.startOfDay(for: createdAt)
        // Adding a day fails only outside the calendar's range of dates.
        return calendar.date(byAdding: .day, value: 1, to: startOfDay)
            ?? startOfDay.addingTimeInterval(secondsPerDay)
    }

    static func initialSchedule(for item: MemoryItem, calendar: Calendar = .current) -> MemorySchedule {
        MemorySchedule(
            memoryItemID: item.id,
            dueAt: firstEligibleAt(createdAt: item.createdAt, calendar: calendar)
        )
    }

    /// The item's first local day, from its first moment to the start of the
    /// next day in `calendar`: the day it was kept, on which it is never due.
    static func firstDay(of item: MemoryItem, calendar: Calendar = .current) -> Range<Date> {
        let start = calendar.startOfDay(for: item.createdAt)
        return start..<max(start, firstEligibleAt(createdAt: item.createdAt, calendar: calendar))
    }

    static func schedule(
        item: MemoryItem,
        attempts: [MemoryAttempt],
        calendar: Calendar = .current
    ) -> MemorySchedule {
        schedule(item: item, attempts: attempts, firstDay: firstDay(of: item, calendar: calendar))
    }

    /// The schedule with the item's first local day given by the caller: what `calendar` would give,
    /// computed by a host that counts days without time-zone data (`CardScheduleFold`). The item is
    /// first eligible at the day's end.
    static func schedule(
        item: MemoryItem,
        attempts: [MemoryAttempt],
        firstDay: Range<Date>
    ) -> MemorySchedule {
        attempts
            .filter { $0.memoryItemID == item.id }
            .sorted {
                if $0.attemptedAt != $1.attemptedAt { return $0.attemptedAt < $1.attemptedAt }
                return $0.id < $1.id
            }
            .reduce(MemorySchedule(memoryItemID: item.id, dueAt: firstDay.upperBound)) { schedule, attempt in
                applying(attempt, to: schedule, firstDay: firstDay)
            }
    }

    /// One attempt applied to a schedule. `firstDay` is the item's first local
    /// day (`firstDay(of:calendar:)`): an answer given inside it leaves the item
    /// due no sooner than the day's end. Nil applies no such floor.
    static func applying(
        _ attempt: MemoryAttempt,
        to schedule: MemorySchedule,
        firstDay: Range<Date>? = nil
    ) -> MemorySchedule {
        guard attempt.memoryItemID == schedule.memoryItemID else { return schedule }

        let lastAttemptAt = maxDate(schedule.lastAttemptAt, attempt.attemptedAt)
        guard attempt.gradeState == .graded, let rating = attempt.scheduleRating else {
            return MemorySchedule(
                memoryItemID: schedule.memoryItemID,
                dueAt: schedule.dueAt,
                lastAttemptAt: lastAttemptAt,
                lastSuccessAt: schedule.lastSuccessAt,
                stability: schedule.stability,
                difficulty: schedule.difficulty,
                repetitionCount: schedule.repetitionCount,
                lapseCount: schedule.lapseCount,
                algorithmVersion: algorithmVersion
            )
        }

        let successful = rating != .again
        if successful, !schedule.isNew, attempt.attemptedAt < schedule.dueAt {
            // Early: the answer came out of short-term memory as much as long-term,
            // so it is counted and leaves the interval alone.
            return MemorySchedule(
                memoryItemID: schedule.memoryItemID,
                dueAt: schedule.dueAt,
                lastAttemptAt: lastAttemptAt,
                lastSuccessAt: maxDate(schedule.lastSuccessAt, attempt.attemptedAt),
                stability: schedule.stability,
                difficulty: schedule.difficulty,
                repetitionCount: schedule.repetitionCount + 1,
                lapseCount: schedule.lapseCount,
                algorithmVersion: algorithmVersion
            )
        }

        let startingStability: Double
        if schedule.stability > 0 {
            startingStability = schedule.stability
        } else {
            switch rating {
            case .again: startingStability = 0.5
            case .hard: startingStability = 1
            case .good: startingStability = 2
            case .easy: startingStability = 4
            }
        }

        let multiplier: Double
        let difficultyDelta: Double
        switch rating {
        case .again:
            multiplier = 0.5
            difficultyDelta = 0.15
        case .hard:
            multiplier = 1.4
            difficultyDelta = 0.05
        case .good:
            multiplier = 2.1
            difficultyDelta = -0.03
        case .easy:
            multiplier = 3
            difficultyDelta = -0.08
        }

        let stability: Double = Swift.min(
            maximumStabilityDays,
            Swift.max(minimumStabilityDays, startingStability * multiplier)
        )
        let difficulty: Double = Swift.min(
            0.95,
            Swift.max(0.05, schedule.difficulty + difficultyDelta)
        )
        var dueAt = attempt.attemptedAt.addingTimeInterval(stability * secondsPerDay)
        if let firstDay, firstDay.contains(attempt.attemptedAt) {
            // Not on the day of consumption: at the earliest, tomorrow.
            dueAt = max(dueAt, firstDay.upperBound)
        }

        return MemorySchedule(
            memoryItemID: schedule.memoryItemID,
            dueAt: dueAt,
            lastAttemptAt: lastAttemptAt,
            lastSuccessAt: successful
                ? maxDate(schedule.lastSuccessAt, attempt.attemptedAt)
                : schedule.lastSuccessAt,
            stability: stability,
            difficulty: difficulty,
            repetitionCount: schedule.repetitionCount + 1,
            lapseCount: schedule.lapseCount + (rating == .again ? 1 : 0),
            algorithmVersion: algorithmVersion
        )
    }

    private static func maxDate(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else { return rhs }
        return max(lhs, rhs)
    }
}
