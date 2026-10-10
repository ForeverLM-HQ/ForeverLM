#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - A card's schedule from Sitting answers (docs/cloudkit-schema-design.md §8c)
//
// Under schema v2 a card's history is the answers about it in the learner's Sittings. Scheduling is a
// fold over the answers that count, deduplicated by answer id and taken in (at, answer id) order, per
// card, through today's scheduler, `MemoryTutorScheduler`: this file only adapts. The one input
// outside the answers is where the learner's days begin, which places a new card's first eligible
// moment. The host computes the learner's UTC offsets (Swift `TimeZone`, JS `Intl`) and passes them
// in, so the fold counts days with fixed offsets and needs no time-zone data: the WebAssembly build,
// FoundationEssentials on WASI, has none, and would count days in UTC from an IANA name.
// `schema/vectors/card-schedule.json` pins the fold for every client, non-UTC zones and DST included.

/// The learner's UTC offset over time, as the host computed it: each sample is the offset in effect
/// from its instant until the next sample, and the first one also before it. A zone's own transitions
/// (`CardScheduleOffsets(timeZone:from:to:)`) give every day boundary exactly.
struct CardScheduleOffsets: Codable, Equatable, Sendable {
    struct Sample: Codable, Equatable, Sendable {
        /// Milliseconds since 1970.
        let at: Int64
        /// Seconds east of UTC.
        let seconds: Int
    }

    let samples: [Sample]

    init(samples: [Sample]) {
        self.samples = samples.sorted { $0.at < $1.at }
    }

    /// One fixed offset.
    init(fixedSeconds seconds: Int) {
        self.samples = [Sample(at: 0, seconds: seconds)]
    }

    func seconds(at milliseconds: Int64) -> Int {
        var current = samples.first?.seconds ?? 0
        for sample in samples {
            guard sample.at <= milliseconds else { break }
            current = sample.seconds
        }
        return current
    }

    /// The instants an offset changes, in order.
    var transitions: [Int64] {
        zip(samples, samples.dropFirst()).compactMap { $0.seconds != $1.seconds ? $1.at : nil }
    }

    #if !os(WASI)
    /// `timeZone`'s offsets from `start` to `end`: its offset at `start`, then each transition up to
    /// `end`. The Mac's and the iPhone's host for the fold.
    init(timeZone: TimeZone, from start: Date, to end: Date) {
        var samples = [Sample(at: CardScheduleFold.milliseconds(start), seconds: timeZone.secondsFromGMT(for: start))]
        var cursor = start
        while let next = timeZone.nextDaylightSavingTimeTransition(after: cursor), next <= end {
            samples.append(Sample(at: CardScheduleFold.milliseconds(next), seconds: timeZone.secondsFromGMT(for: next)))
            cursor = next
        }
        self.init(samples: samples)
    }
    #endif
}

/// A card as the fold reads it: its id and when it was kept. A card no answer reached yet is new and
/// first eligible at the start of the local day after `keptAt`.
struct CardScheduleCard: Codable, Equatable, Sendable {
    let id: String
    /// Milliseconds since 1970.
    let keptAt: Int64
}

/// One Sitting answer as the fold reads it (§3.5.23 `Answer`): its id, its subject (`crd:<id>` for a
/// card), when it was given, its rating and grade state, and whether it counts toward scheduling.
struct CardScheduleAnswer: Codable, Equatable, Sendable {
    let answerID: String
    let subject: String
    /// Milliseconds since 1970.
    let at: Int64
    let rating: String?
    let gradeState: String?
    let counted: Bool?

    init(answerID: String, subject: String, at: Int64, rating: String? = nil, gradeState: String? = nil, counted: Bool? = true) {
        self.answerID = answerID
        self.subject = subject
        self.at = at
        self.rating = rating
        self.gradeState = gradeState
        self.counted = counted
    }

    /// The card this answer is about; nil for an answer about anything else.
    var cardID: String? {
        guard subject.hasPrefix("crd:") else { return nil }
        let id = subject.dropFirst(4).split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return id.isEmpty ? nil : id
    }
}

enum CardScheduleFold {
    static let millisecondsPerDay: Int64 = 86_400_000

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }

    /// The answers that schedule cards, as attempts: about a card, counted, once each by answer id. An
    /// answer with a rating and no grade state is graded (a self-graded Remembered or Forgot).
    static func attempts(from answers: [CardScheduleAnswer]) -> [MemoryAttempt] {
        var seen = Set<String>()
        var attempts: [MemoryAttempt] = []
        for answer in answers.sorted(by: { ($0.at, $0.answerID) < ($1.at, $1.answerID) }) {
            guard answer.counted != false, let cardID = answer.cardID, seen.insert(answer.answerID).inserted else { continue }
            let rating = answer.rating.flatMap(MemoryScheduleRating.init(rawValue:))
            let gradeState = answer.gradeState.flatMap(MemoryGradeState.init(rawValue:)) ?? (rating == nil ? .pending : .graded)
            attempts.append(MemoryAttempt(
                id: answer.answerID, memoryItemID: cardID, prompt: "", learnerAnswer: "",
                scheduleRating: gradeState == .graded ? rating : nil, gradeState: gradeState, attemptedAt: date(answer.at)
            ))
        }
        return attempts
    }

    /// The local day number of an instant: whole days since 1970 in the offset in effect then.
    static func localDay(_ milliseconds: Int64, offsets: CardScheduleOffsets) -> Int64 {
        floorDivide(milliseconds + Int64(offsets.seconds(at: milliseconds)) * 1_000, millisecondsPerDay)
    }

    /// The first instant of local day `day`, near `near`: midnight in each offset in effect within two
    /// days of it (on both sides of every transition there), or a transition that skips midnight,
    /// whichever comes first and is in that day.
    static func start(ofDay day: Int64, near: Int64, offsets: CardScheduleOffsets) -> Int64 {
        let window = (near - 2 * millisecondsPerDay)...(near + 2 * millisecondsPerDay)
        var candidates = offsets.transitions.filter { window.contains($0) }
        var offsetsNear = Set([offsets.seconds(at: near)])
        for transition in candidates {
            offsetsNear.insert(offsets.seconds(at: transition - 1))
            offsetsNear.insert(offsets.seconds(at: transition))
        }
        for seconds in offsetsNear { candidates.append(day * millisecondsPerDay - Int64(seconds) * 1_000) }
        return candidates.filter { localDay($0, offsets: offsets) == day }.min()
            ?? (day * millisecondsPerDay - Int64(offsets.seconds(at: near)) * 1_000)
    }

    /// The local day that holds `milliseconds`, from its first instant to the next day's.
    static func day(containing milliseconds: Int64, offsets: CardScheduleOffsets) -> Range<Int64> {
        let day = Self.localDay(milliseconds, offsets: offsets)
        let start = Self.start(ofDay: day, near: milliseconds, offsets: offsets)
        let end = Self.start(ofDay: day + 1, near: milliseconds + millisecondsPerDay, offsets: offsets)
        return start..<max(start, end)
    }

    /// A card's first local day, the day it was kept, on which it is never due
    /// (`MemoryTutorScheduler.firstDay`).
    static func firstDay(keptAt: Int64, offsets: CardScheduleOffsets) -> Range<Date> {
        let day = Self.day(containing: keptAt, offsets: offsets)
        return date(day.lowerBound)..<date(day.upperBound)
    }

    /// One card's schedule from every answer given (the others are ignored).
    static func schedule(card: CardScheduleCard, answers: [CardScheduleAnswer], offsets: CardScheduleOffsets) -> MemorySchedule {
        let item = MemoryItem(id: card.id, kind: .concept, target: "", rubricJSON: "{}", sources: [],
                              createdAt: date(card.keptAt), updatedAt: date(card.keptAt))
        let attempts = Self.attempts(from: answers).filter { $0.memoryItemID == card.id }
        return MemoryTutorScheduler.schedule(item: item, attempts: attempts, firstDay: firstDay(keptAt: card.keptAt, offsets: offsets))
    }

    /// Every card's schedule, by card id.
    static func schedules(cards: [CardScheduleCard], answers: [CardScheduleAnswer], offsets: CardScheduleOffsets) -> [String: MemorySchedule] {
        let attempts = Dictionary(grouping: Self.attempts(from: answers), by: \.memoryItemID)
        var schedules: [String: MemorySchedule] = [:]
        for card in cards where schedules[card.id] == nil {
            let item = MemoryItem(id: card.id, kind: .concept, target: "", rubricJSON: "{}", sources: [],
                                  createdAt: date(card.keptAt), updatedAt: date(card.keptAt))
            schedules[card.id] = MemoryTutorScheduler.schedule(
                item: item, attempts: attempts[card.id] ?? [], firstDay: firstDay(keptAt: card.keptAt, offsets: offsets)
            )
        }
        return schedules
    }

    private static func floorDivide(_ value: Int64, _ divisor: Int64) -> Int64 {
        let quotient = value / divisor
        return (value % divisor != 0 && (value < 0) != (divisor < 0)) ? quotient - 1 : quotient
    }
}

// MARK: - JSON in and out (the WebAssembly bridge and the shared vectors)

extension CardScheduleFold {
    struct Input: Codable, Equatable, Sendable {
        let cards: [CardScheduleCard]
        let answers: [CardScheduleAnswer]
        let offsets: CardScheduleOffsets
    }

    /// A schedule on the wire: times in milliseconds since 1970.
    struct Output: Codable, Equatable, Sendable {
        let dueAt: Int64
        let lastAttemptAt: Int64?
        let lastSuccessAt: Int64?
        let stability: Double
        let difficulty: Double
        let repetitionCount: Int
        let lapseCount: Int

        init(_ schedule: MemorySchedule) {
            dueAt = CardScheduleFold.milliseconds(schedule.dueAt)
            lastAttemptAt = schedule.lastAttemptAt.map(CardScheduleFold.milliseconds)
            lastSuccessAt = schedule.lastSuccessAt.map(CardScheduleFold.milliseconds)
            stability = schedule.stability
            difficulty = schedule.difficulty
            repetitionCount = schedule.repetitionCount
            lapseCount = schedule.lapseCount
        }
    }

    /// `{cards, answers, offsets}` in, `{cardID: schedule}` out, keys sorted; nil for input that is
    /// not that shape.
    static func run(json: String) -> String? {
        guard let input = try? JSONDecoder().decode(Input.self, from: Data(json.utf8)) else { return nil }
        let schedules = Self.schedules(cards: input.cards, answers: input.answers, offsets: input.offsets).mapValues(Output.init)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(schedules) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

extension ForeverLMCore {
    /// The card schedule fold for the WebAssembly bridge: `{cards, answers, offsets}` as JSON in, each
    /// card's schedule as JSON out (`CardScheduleFold.run(json:)`); nil for input of another shape.
    public static func cardScheduleFold(json: String) -> String? {
        CardScheduleFold.run(json: json)
    }
}
