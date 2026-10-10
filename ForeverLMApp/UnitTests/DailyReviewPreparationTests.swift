import Foundation
import Testing
@testable import ForeverLM

/// The timing rules behind preparing today's review ahead of the click. Pure,
/// so a clock and a calendar are all a test needs.
@Suite("Daily review preparation timing")
struct DailyReviewPreparationTests {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test("The preparation instant is the hour, on the dot, on the day given")
    func preparationInstantIsTheHourOnTheDay() {
        let now = date(2026, 9, 4, 13, 37)
        let instant = DailyReviewPreparation.preparationInstant(onDayOf: now, hour: 7, calendar: calendar)
        #expect(instant == date(2026, 9, 4, 7))
    }

    @Test("The next instant is today's hour while it is ahead, otherwise tomorrow's")
    func nextInstantRollsToTomorrowOncePassed() {
        let beforeHour = date(2026, 9, 4, 6, 59)
        #expect(DailyReviewPreparation.nextPreparationInstant(after: beforeHour, hour: 7, calendar: calendar) == date(2026, 9, 4, 7))

        let atHour = date(2026, 9, 4, 7)
        #expect(DailyReviewPreparation.nextPreparationInstant(after: atHour, hour: 7, calendar: calendar) == date(2026, 9, 5, 7))

        let afterHour = date(2026, 9, 4, 22, 15)
        #expect(DailyReviewPreparation.nextPreparationInstant(after: afterHour, hour: 7, calendar: calendar) == date(2026, 9, 5, 7))
    }

    @Test("Hours clamp to a day")
    func hoursClamp() {
        #expect(DailyReviewPreparation.clampHour(-3) == 0)
        #expect(DailyReviewPreparation.clampHour(7) == 7)
        #expect(DailyReviewPreparation.clampHour(31) == 23)
    }

    @Test("Off means nothing happens, whatever the clock says")
    func disabledNeverPrepares() {
        let decision = DailyReviewPreparation.decide(
            now: date(2026, 9, 4, 9),
            isEnabled: false,
            hour: 7,
            todaysSessionExists: false,
            lastAttemptDay: nil,
            calendar: calendar
        )
        #expect(decision == .disabled)
    }

    @Test("Before the hour the answer is not yet; from the hour on it is prepare")
    func hourGatesPreparation() {
        let early = DailyReviewPreparation.decide(
            now: date(2026, 9, 4, 6, 59),
            isEnabled: true,
            hour: 7,
            todaysSessionExists: false,
            lastAttemptDay: nil,
            calendar: calendar
        )
        #expect(early == .notYet)

        let onTime = DailyReviewPreparation.decide(
            now: date(2026, 9, 4, 7),
            isEnabled: true,
            hour: 7,
            todaysSessionExists: false,
            lastAttemptDay: nil,
            calendar: calendar
        )
        #expect(onTime == .prepare)

        // A Mac that was closed at 7 catches up whenever it is next opened.
        let late = DailyReviewPreparation.decide(
            now: date(2026, 9, 4, 21, 30),
            isEnabled: true,
            hour: 7,
            todaysSessionExists: false,
            lastAttemptDay: nil,
            calendar: calendar
        )
        #expect(late == .prepare)
    }

    @Test("An existing chat for today wins over every other consideration")
    func existingSessionMeansNothingToDo() {
        let decision = DailyReviewPreparation.decide(
            now: date(2026, 9, 4, 9),
            isEnabled: true,
            hour: 7,
            todaysSessionExists: true,
            lastAttemptDay: nil,
            calendar: calendar
        )
        #expect(decision == .alreadyExists)
    }

    @Test("One attempt a day per device: a failed morning is not retried until tomorrow")
    func oneAttemptPerDay() {
        let now = date(2026, 9, 4, 9)
        let today = DailyReviewPreparation.dayKey(for: now, calendar: calendar)
        let yesterday = DailyReviewPreparation.dayKey(for: date(2026, 9, 3, 9), calendar: calendar)

        let attemptedToday = DailyReviewPreparation.decide(
            now: now, isEnabled: true, hour: 7,
            todaysSessionExists: false, lastAttemptDay: today, calendar: calendar
        )
        #expect(attemptedToday == .alreadyAttempted)

        let attemptedYesterday = DailyReviewPreparation.decide(
            now: now, isEnabled: true, hour: 7,
            todaysSessionExists: false, lastAttemptDay: yesterday, calendar: calendar
        )
        #expect(attemptedYesterday == .prepare)
    }

    @Test("The day key is the day's session id, so 'attempted today' and 'today's chat' agree")
    func dayKeyMatchesSessionID() {
        let now = date(2026, 9, 4, 9)
        #expect(DailyReviewPreparation.dayKey(for: now, calendar: calendar) == MemoryReviewSession.sessionID(for: now, calendar: calendar))
        #expect(DailyReviewPreparation.dayKey(for: now, calendar: calendar) == "memory-2026-09-04")
    }

    @Test("The hour label follows the locale's clock")
    func hourLabelFollowsLocale() {
        // Foundation separates "7" and "AM" with a narrow no-break space on
        // current macOS; the test cares about the digits and the convention.
        func squeezed(_ label: String) -> String {
            label.replacingOccurrences(of: "\u{202F}", with: "").replacingOccurrences(of: " ", with: "")
        }
        #expect(squeezed(DailyReviewPreparation.hourLabel(7, calendar: calendar, locale: Locale(identifier: "en_US"))) == "7:00AM")
        #expect(squeezed(DailyReviewPreparation.hourLabel(19, calendar: calendar, locale: Locale(identifier: "en_US"))) == "7:00PM")
        // A 24-hour clock keeps the minutes too: "19" alone reads as a code, not a time.
        #expect(squeezed(DailyReviewPreparation.hourLabel(19, calendar: calendar, locale: Locale(identifier: "nl_NL"))) == "19:00")
        #expect(squeezed(DailyReviewPreparation.hourLabel(7, calendar: calendar, locale: Locale(identifier: "nl_NL"))) == "07:00")
    }

    @Test("The in-chat offer stands until it is taken, decided in Settings, or has passed a few times")
    func offerRetiresWithoutAnAnswer() {
        #expect(DailyReviewPreparation.offerStands(isEnabled: false, decided: false, shownCount: 0))
        #expect(DailyReviewPreparation.offerStands(isEnabled: false, decided: false, shownCount: DailyReviewPreparation.maxOfferShowings - 1))
        #expect(!DailyReviewPreparation.offerStands(isEnabled: false, decided: false, shownCount: DailyReviewPreparation.maxOfferShowings))
        #expect(!DailyReviewPreparation.offerStands(isEnabled: true, decided: false, shownCount: 0))
        #expect(!DailyReviewPreparation.offerStands(isEnabled: false, decided: true, shownCount: 0))
    }
}
