import Foundation
import Testing
@testable import ForeverLM

/// A quarter's and a week's plan (`PlanPeriod`): the ids that make one record
/// per period on every Mac, the titles that link them, and the calendar
/// arithmetic the Plan place and `get_plan` step through.
@Suite("Plan periods")
struct PlanPeriodTests {
    private let zone = TimeZone(identifier: "Europe/Amsterdam")!

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return PlanPeriod.gregorian(zone).date(from: components)!
    }

    @Test("A day falls in its calendar quarter and its ISO week")
    func containing() {
        #expect(PlanPeriod.containing(day(2026, 11, 7), scale: .quarter, zone: zone) == .quarter(year: 2026, quarter: 4))
        #expect(PlanPeriod.containing(day(2026, 3, 31), scale: .quarter, zone: zone) == .quarter(year: 2026, quarter: 1))
        #expect(PlanPeriod.containing(day(2026, 4, 1), scale: .quarter, zone: zone) == .quarter(year: 2026, quarter: 2))
        // Saturday November 7th, 2026 is in ISO week 45, which starts on Monday the 2nd.
        #expect(PlanPeriod.containing(day(2026, 11, 7), scale: .week, zone: zone) == .week(year: 2026, week: 45))
        #expect(PlanPeriod.containing(day(2026, 11, 8), scale: .week, zone: zone) == .week(year: 2026, week: 45))
        #expect(PlanPeriod.containing(day(2026, 11, 9), scale: .week, zone: zone) == .week(year: 2026, week: 46))
        // January 1st, 2027 is a Friday: still the last week of ISO 2026.
        #expect(PlanPeriod.containing(day(2027, 1, 1), scale: .week, zone: zone) == .week(year: 2026, week: 53))
    }

    @Test("Ids and keys round-trip, and nothing else reads as a plan")
    func identity() {
        let quarter = PlanPeriod.quarter(year: 2026, quarter: 4)
        let week = PlanPeriod.week(year: 2026, week: 45)
        #expect(quarter.key == "2026-Q4")
        #expect(quarter.id == "plan-2026-q4")
        #expect(week.key == "2026-W45")
        #expect(week.id == "plan-2026-w45")
        #expect(PlanPeriod(id: quarter.id) == quarter)
        #expect(PlanPeriod(id: week.id) == week)
        #expect(PlanPeriod(key: "2026-q4") == quarter)
        #expect(PlanPeriod(key: "2026-W5") == nil, "weeks are two digits")
        #expect(PlanPeriod(key: "2026-Q5") == nil)
        #expect(PlanPeriod(key: "2026-W53") == .week(year: 2026, week: 53), "2026 has 53 ISO weeks")
        #expect(PlanPeriod(key: "2025-W53") == nil, "2025 has 52")
        #expect(PlanPeriod(id: "plan-2026-W45") == nil, "an id is lower case")
        #expect(!PlanPeriod.isPlanID("daily-2026-11-07"))
        #expect(!PlanPeriod.isPlanID("plan-day"))
        #expect(!PlanPeriod.isPlanID("2026-q4"))
    }

    @Test("Titles name the period and read back, a week only by its Monday")
    func titles() {
        let quarter = PlanPeriod.quarter(year: 2026, quarter: 4)
        let week = PlanPeriod.week(year: 2026, week: 45)
        #expect(quarter.title(zone: zone) == "Q4 2026")
        #expect(week.title(zone: zone) == "Week of November 2nd, 2026")
        #expect(PlanPeriod(title: "Q4 2026", zone: zone) == quarter)
        #expect(PlanPeriod(title: "q4 2026", zone: zone) == quarter)
        #expect(PlanPeriod(title: "Week of November 2nd, 2026", zone: zone) == week)
        #expect(PlanPeriod(title: "Week of November 2, 2026", zone: zone) == week)
        #expect(PlanPeriod(title: "Week of November 3rd, 2026", zone: zone) == nil, "a Tuesday names no week")
        #expect(PlanPeriod(title: "November 2nd, 2026", zone: zone) == nil, "a daily note's title is no plan's")
        #expect(PlanPeriod(title: "Q4 planning", zone: zone) == nil)
    }

    @Test("Stepping moves by whole quarters and weeks, across years")
    func stepping() {
        #expect(PlanPeriod.quarter(year: 2026, quarter: 4).offset(by: 1, zone: zone) == .quarter(year: 2027, quarter: 1))
        #expect(PlanPeriod.quarter(year: 2026, quarter: 1).offset(by: -1, zone: zone) == .quarter(year: 2025, quarter: 4))
        #expect(PlanPeriod.week(year: 2026, week: 53).offset(by: 1, zone: zone) == .week(year: 2027, week: 1))
        #expect(PlanPeriod.week(year: 2026, week: 1).offset(by: -1, zone: zone) == .week(year: 2025, week: 52))
        // Across the autumn clock change (October 25th, 2026, in Amsterdam).
        #expect(PlanPeriod.week(year: 2026, week: 43).offset(by: 1, zone: zone) == .week(year: 2026, week: 44))
    }

    @Test("A quarter's weeks are the weeks whose Thursday it holds")
    func weeksOfAQuarter() {
        let q4 = PlanPeriod.quarter(year: 2026, quarter: 4).weeks(zone: zone)
        // Week 40 runs September 28th – October 4th; its Thursday is October 1st.
        #expect(q4.first == .week(year: 2026, week: 40))
        #expect(q4.last == .week(year: 2026, week: 53))
        #expect(q4.count == 14)
        let q1 = PlanPeriod.quarter(year: 2027, quarter: 1).weeks(zone: zone)
        #expect(q1.first == .week(year: 2027, week: 1))
        #expect(q1.count == 12, "2027's first quarter has twelve Thursdays")
        for week in q4 {
            #expect(week.quarter(zone: zone) == .quarter(year: 2026, quarter: 4))
        }
    }

    @Test("A period spans its days")
    func ranges() {
        let locale = Locale(identifier: "en_US")
        #expect(PlanPeriod.quarter(year: 2026, quarter: 4).rangeText(zone: zone, locale: locale) == "Oct 1 – Dec 31")
        #expect(PlanPeriod.week(year: 2026, week: 45).rangeText(zone: zone, locale: locale) == "Nov 2 – 8")
        #expect(PlanPeriod.week(year: 2026, week: 53).rangeText(zone: zone, locale: locale) == "Dec 28 – Jan 3")
        #expect(PlanPeriod.week(year: 2026, week: 45).days(zone: zone).count == 7)
    }

    @Test("A new plan starts from Newport's headings; a week links its quarter and lists its days")
    func templates() {
        let quarter = PlanPeriod.quarter(year: 2026, quarter: 4).template(zone: zone)
        for heading in ["## Objectives", "## Strategies", "## Not this quarter", "## Looking back"] {
            #expect(quarter.contains(heading))
        }
        #expect(!quarter.hasPrefix("# "), "a plan is named by its period, not its body")
        let week = PlanPeriod.week(year: 2026, week: 45).template(zone: zone)
        #expect(week.hasPrefix("Quarter: [[Q4 2026]]"))
        for heading in ["## Big rocks", "## Deep work", "## Days", "## Looking back"] {
            #expect(week.contains(heading))
        }
        #expect(week.contains("- Monday: "))
        #expect(week.contains("- Sunday: "))
    }

    @Test("get_plan reads a day, a key, a title, or this, next and last")
    func mcpPeriodArgument() throws {
        let now = day(2026, 11, 7)
        func period(_ scale: PlanScale, _ value: Any?) throws -> PlanPeriod {
            try MCPDataStore.planPeriod(scale: scale, from: value, now: now, zone: zone)
        }
        #expect(try period(.quarter, nil) == .quarter(year: 2026, quarter: 4))
        #expect(try period(.week, "") == .week(year: 2026, week: 45))
        #expect(try period(.week, "next") == .week(year: 2026, week: 46))
        #expect(try period(.quarter, "last") == .quarter(year: 2026, quarter: 3))
        #expect(try period(.week, "2026-11-11") == .week(year: 2026, week: 46))
        #expect(try period(.quarter, "2027-Q1") == .quarter(year: 2027, quarter: 1))
        #expect(try period(.quarter, "Q2 2026") == .quarter(year: 2026, quarter: 2))
        #expect(throws: MCPError.self) { try period(.quarter, "2026-W45") }
        #expect(throws: MCPError.self) { try period(.week, "sometime") }
    }

    @Test("The popover reads a section's written bullets, the template's empty ones left out")
    func outlineItems() {
        let markdown = """
        ## Objectives

        - Finish the **mtDNA** thesis for [[Norn Nexus]] ^abc123def
        - [ ] Ship the Plan place
          - a sub-point stays out
        1. Numbered counts too
        - 

        ## Strategies

        - Not an objective
        """
        #expect(PlanOutline.items(under: "Objectives", in: markdown)
            == ["Finish the mtDNA thesis for Norn Nexus", "Ship the Plan place", "Numbered counts too"])
        #expect(PlanOutline.items(under: "objectives", in: markdown, limit: 1) == ["Finish the mtDNA thesis for Norn Nexus"])
        #expect(PlanOutline.items(under: "Strategies", in: markdown) == ["Not an objective"])
        #expect(PlanOutline.items(under: "Looking back", in: markdown).isEmpty)
        // A fresh template says nothing.
        #expect(PlanOutline.items(under: "Objectives", in: PlanPeriod.quarter(year: 2026, quarter: 4).template(zone: zone)).isEmpty)
    }

    @Test("Today's line is read from the week's Days by its weekday")
    func outlineDayLine() {
        var week = PlanPeriod.week(year: 2026, week: 45).template(zone: zone)
        #expect(PlanOutline.dayLine("Saturday", in: week) == nil, "an empty line says nothing")
        week = week.replacingOccurrences(of: "- Saturday: ", with: "- Saturday: Write the Q4 review")
        #expect(PlanOutline.dayLine("Saturday", in: week) == "Write the Q4 review")
        #expect(PlanOutline.dayLine("Sunday", in: week) == nil)
        #expect(PlanOutline.weekdayName(of: day(2026, 11, 7), zone: zone) == "Saturday")
    }
}
