import Foundation
import Testing
@testable import ForeverLM

/// `CardScheduleFold` (docs/cloudkit-schema-design.md §8c): a card's schedule from Sitting answers,
/// through today's scheduler, with the learner's day boundaries from host-computed UTC offsets. The
/// shared vectors (`schema/vectors/card-schedule.json`) hold the live-shaped library in six zones,
/// late-evening answers and DST transitions; each case must equal today's scheduler run with a calendar
/// in the case's zone, and the fold must give it from the offsets alone.
@Suite("Card schedule fold")
struct CardScheduleFoldTests {
    private static func vectorCases() throws -> [SyncJSON] {
        let directory = try #require(SyncVectorRunner.directory, "schema/vectors is not in the test bundle")
        let data = try Data(contentsOf: directory.appendingPathComponent("card-schedule.json"))
        return try #require(try SyncJSON(parsing: data)["cases"]?.arrayValue)
    }

    private static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    private static func ms(_ text: String, _ zone: TimeZone) -> Int64 {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return CardScheduleFold.milliseconds(formatter.date(from: text)!)
    }

    @Test("Every vector case: today's scheduler in the case's zone gives the expectation, and the fold gives it from the offsets")
    func vectors() throws {
        let cases = try Self.vectorCases()
        #expect(cases.count >= 13)
        var zones = Set<String>()
        for entry in cases {
            let name = entry["name"]?.stringValue ?? "?"
            let zoneName = try #require(entry["zone"]?.stringValue, "\(name) names a zone")
            let zone = try #require(TimeZone(identifier: zoneName))
            zones.insert(zoneName)
            let input = try JSONDecoder().decode(CardScheduleFold.Input.self, from: try #require(entry["input"]).serialized())
            let expected = try JSONDecoder().decode([String: CardScheduleFold.Output].self, from: try #require(entry["expect"]).serialized())

            let attempts = CardScheduleFold.attempts(from: input.answers)
            for card in input.cards {
                let item = MemoryItem(id: card.id, kind: .concept, target: "", rubricJSON: "{}", sources: [],
                                      createdAt: CardScheduleFold.date(card.keptAt), updatedAt: CardScheduleFold.date(card.keptAt))
                let scheduler = MemoryTutorScheduler.schedule(item: item, attempts: attempts, calendar: Self.calendar(zone))
                #expect(CardScheduleFold.Output(scheduler) == expected[card.id], "\(name): today's scheduler for \(card.id)")
            }
            let folded = CardScheduleFold.schedules(cards: input.cards, answers: input.answers, offsets: input.offsets)
            #expect(folded.mapValues(CardScheduleFold.Output.init) == expected, "\(name): the fold")
        }
        #expect(zones.isSuperset(of: ["UTC", "America/New_York", "Europe/London", "America/Sao_Paulo", "Australia/Lord_Howe", "Pacific/Chatham"]))
    }

    @Test("Answers are folded once each by id; uncounted answers and other subjects do not schedule")
    func answersDeduplicatedAndFiltered() {
        let zone = TimeZone(identifier: "Asia/Tokyo")!
        let card = CardScheduleCard(id: "card-1", keptAt: Self.ms("2026-06-01 09:00", zone))
        let good = CardScheduleAnswer(answerID: "a-1", subject: "crd:card-1", at: Self.ms("2026-06-02 08:00", zone), rating: "good")
        let offsets = CardScheduleOffsets(timeZone: zone, from: Date(timeIntervalSince1970: 1_780_000_000), to: Date(timeIntervalSince1970: 1_782_000_000))
        let once = CardScheduleFold.schedule(card: card, answers: [good], offsets: offsets)
        #expect(once.repetitionCount == 1)

        let twice = CardScheduleFold.schedule(card: card, answers: [good, good], offsets: offsets)
        #expect(twice == once, "the same answer in two parts is one answer")
        let uncounted = CardScheduleAnswer(answerID: "a-2", subject: "crd:card-1", at: Self.ms("2026-06-03 08:00", zone), rating: "again", counted: false)
        let quiz = CardScheduleAnswer(answerID: "a-3", subject: "qz:cq-1#q1", at: Self.ms("2026-06-03 09:00", zone), rating: "again")
        let other = CardScheduleAnswer(answerID: "a-4", subject: "crd:card-2", at: Self.ms("2026-06-03 10:00", zone), rating: "again")
        #expect(CardScheduleFold.schedule(card: card, answers: [good, uncounted, quiz, other], offsets: offsets) == once)

        // The scheduler fed exactly the one counted answer agrees.
        let item = MemoryItem(id: "card-1", kind: .concept, target: "", rubricJSON: "{}", sources: [],
                              createdAt: CardScheduleFold.date(card.keptAt), updatedAt: CardScheduleFold.date(card.keptAt))
        let attempt = MemoryAttempt(id: "a-1", memoryItemID: "card-1", prompt: "", learnerAnswer: "", scheduleRating: .good,
                                    gradeState: .graded, attemptedAt: CardScheduleFold.date(good.at))
        #expect(MemoryTutorScheduler.schedule(item: item, attempts: [attempt], calendar: Self.calendar(zone)) == once)

        // A counted miss does move it, so the filter is what kept the uncounted one out.
        let counted = CardScheduleAnswer(answerID: "a-2", subject: "crd:card-1", at: uncounted.at, rating: "again")
        #expect(CardScheduleFold.schedule(card: card, answers: [good, counted], offsets: offsets).lapseCount == 1)
    }

    @Test("Days are counted in the host's offsets: the same answers in two zones fall due on their own midnights")
    func offsetsDecideTheDay() {
        // Kept at 22:30 UTC, never answered: first eligible at the next local midnight.
        let midnight: Int64 = 1_780_000_000_000 - 1_780_000_000_000 % CardScheduleFold.millisecondsPerDay
        let keptAt = midnight + 81_000_000
        let card = CardScheduleCard(id: "card-1", keptAt: keptAt)
        let utc = CardScheduleFold.schedule(card: card, answers: [], offsets: CardScheduleOffsets(fixedSeconds: 0))
        let tokyo = CardScheduleFold.schedule(card: card, answers: [], offsets: CardScheduleOffsets(fixedSeconds: 9 * 3_600))
        #expect(CardScheduleFold.milliseconds(utc.dueAt) == keptAt + 5_400_000, "UTC: midnight is an hour and a half later")
        // 22:30 UTC is 07:30 the next day in Tokyo, so its first day ends at 15:00 UTC the day after.
        #expect(CardScheduleFold.milliseconds(tokyo.dueAt) == keptAt + (16 * 3_600 + 1_800) * 1_000)
    }

    @Test("The JSON entry point the WebAssembly core exports reads the vectors' input and answers their expectation")
    func jsonEntryPoint() throws {
        let entry = try #require(try Self.vectorCases().first)
        let input = try #require(entry["input"])
        let output = try #require(CardScheduleFold.run(json: String(decoding: input.serialized(), as: UTF8.self)))
        #expect(try SyncJSON(parsing: Data(output.utf8)) == entry["expect"])
        #expect(CardScheduleFold.run(json: "{\"cards\": 1}") == nil)
    }

    @Test("The fold holds no time-zone data: TimeZone appears only in the host helper, outside the WebAssembly build")
    func noTimeZoneDataInTheFold() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Shared/Portable/CardScheduleFold.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        var outsideHost: [String] = []
        var inHost = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
            if line.contains("#if !os(WASI)") { inHost = true }
            if !inHost, line.contains("TimeZone") || line.contains("Calendar(") || line.contains(".current") { outsideHost.append(String(line)) }
            if inHost, line.contains("#endif") { inHost = false }
        }
        #expect(outsideHost.isEmpty, "\(outsideHost)")
    }
}
