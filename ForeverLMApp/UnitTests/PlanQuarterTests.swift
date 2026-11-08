import Foundation
import Testing
@testable import ForeverLM

/// The quarter's plan (`PlanQuarter`): the ids that make one record per
/// quarter on every device, the titles that link it, the stepping the Plan
/// place and `get_plan` do, and the outline the day's popover reads. The
/// week and the day are the calendar, so no week is a plan.
@Suite("Plan quarters")
struct PlanQuarterTests {
    private let zone = TimeZone(identifier: "Europe/Amsterdam")!

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return PlanQuarter.gregorian(zone).date(from: components)!
    }

    @Test("A day falls in its calendar quarter")
    func containing() {
        #expect(PlanQuarter.containing(day(2026, 11, 7), zone: zone) == PlanQuarter(year: 2026, quarter: 4))
        #expect(PlanQuarter.containing(day(2026, 3, 31), zone: zone) == PlanQuarter(year: 2026, quarter: 1))
        #expect(PlanQuarter.containing(day(2026, 4, 1), zone: zone) == PlanQuarter(year: 2026, quarter: 2))
    }

    @Test("Ids and keys round-trip, and nothing else reads as a plan, a week least of all")
    func identity() {
        let q4 = PlanQuarter(year: 2026, quarter: 4)
        #expect(q4.key == "2026-Q4")
        #expect(q4.id == "plan-2026-q4")
        #expect(PlanQuarter(id: q4.id) == q4)
        #expect(PlanQuarter(key: "2026-q4") == q4)
        #expect(PlanQuarter(key: "2026-Q5") == nil)
        #expect(PlanQuarter(id: "plan-2026-Q4") == nil, "an id is lower case")
        #expect(!PlanQuarter.isPlanID("plan-2026-w45"))
        #expect(!PlanQuarter.isPlanID("daily-2026-11-07"))
        #expect(!PlanQuarter.isPlanID("plan-day"))
    }

    @Test("The title names the quarter and reads back")
    func titles() {
        let q4 = PlanQuarter(year: 2026, quarter: 4)
        #expect(q4.title == "Q4 2026")
        #expect(PlanQuarter(title: "Q4 2026") == q4)
        #expect(PlanQuarter(title: "q4 2026") == q4)
        #expect(PlanQuarter(title: "Week of November 2nd, 2026") == nil)
        #expect(PlanQuarter(title: "Q4 planning") == nil)
    }

    @Test("Stepping moves by whole quarters, across years, and the range spans the quarter")
    func steppingAndRange() {
        #expect(PlanQuarter(year: 2026, quarter: 4).offset(by: 1) == PlanQuarter(year: 2027, quarter: 1))
        #expect(PlanQuarter(year: 2026, quarter: 1).offset(by: -1) == PlanQuarter(year: 2025, quarter: 4))
        #expect(PlanQuarter(year: 2026, quarter: 2).offset(by: -6) == PlanQuarter(year: 2024, quarter: 4))
        #expect(PlanQuarter(year: 2026, quarter: 4).rangeText(zone: zone, locale: Locale(identifier: "en_US")) == "Oct 1 – Dec 31")
    }

    @Test("A new plan starts from Newport's shape")
    func template() {
        let template = PlanQuarter(year: 2026, quarter: 4).template
        #expect(template.components(separatedBy: "\n").filter { $0.hasPrefix("## ") }
            == ["## Big picture", "## Objectives", "## Strategies and habits", "## Weeks"])
        #expect(template.contains("## \(PlanQuarter.objectivesHeading)"), "the popover reads the objectives by this heading")
        #expect(!template.hasPrefix("# "), "a plan is named by its quarter, not its body")
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

        ## Strategies and habits

        - Not an objective
        """
        #expect(PlanOutline.items(under: "Objectives", in: markdown)
            == ["Finish the mtDNA thesis for Norn Nexus", "Ship the Plan place", "Numbered counts too"])
        #expect(PlanOutline.items(under: "objectives", in: markdown, limit: 1) == ["Finish the mtDNA thesis for Norn Nexus"])
        #expect(PlanOutline.items(under: "Strategies and habits", in: markdown) == ["Not an objective"])
        #expect(PlanOutline.items(under: "Big picture", in: markdown).isEmpty)
        #expect(PlanOutline.items(under: "Objectives", in: PlanQuarter(year: 2026, quarter: 4).template).isEmpty)
    }

    @Test("get_plan reads a day, a key, a title, or this, next and last")
    func mcpQuarterArgument() throws {
        let now = day(2026, 11, 7)
        func quarter(_ value: Any?) throws -> PlanQuarter {
            try MCPDataStore.planQuarter(from: value, now: now, zone: zone)
        }
        #expect(try quarter(nil) == PlanQuarter(year: 2026, quarter: 4))
        #expect(try quarter("") == PlanQuarter(year: 2026, quarter: 4))
        #expect(try quarter("next") == PlanQuarter(year: 2027, quarter: 1))
        #expect(try quarter("last") == PlanQuarter(year: 2026, quarter: 3))
        #expect(try quarter("2026-05-11") == PlanQuarter(year: 2026, quarter: 2))
        #expect(try quarter("2027-Q1") == PlanQuarter(year: 2027, quarter: 1))
        #expect(try quarter("Q2 2026") == PlanQuarter(year: 2026, quarter: 2))
        #expect(throws: MCPError.self) { try quarter("2026-W45") }
        #expect(throws: MCPError.self) { try quarter("sometime") }
    }

    // MARK: The quarter's weeks, read off the calendar

    private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return PlanQuarter.gregorian(zone).date(from: components)!
    }

    @Test("A quarter's weeks run Monday to Sunday, each in the quarter its Thursday is in")
    func weekStarts() {
        let calendar = PlanQuarterWeeks.weekCalendar(zone)
        let q4 = PlanQuarterWeeks.weekStarts(of: PlanQuarter(year: 2026, quarter: 4), calendar: calendar)
        #expect(q4.count == 14)
        #expect(q4.first == at(2026, 9, 28, 0), "Thursday Oct 1 makes Sep 28's week Q4's")
        #expect(q4.last == at(2026, 12, 28, 0), "Thursday Dec 31 keeps the last week in Q4")
        let q1 = PlanQuarterWeeks.weekStarts(of: PlanQuarter(year: 2027, quarter: 1), calendar: calendar)
        #expect(q1.first == at(2027, 1, 4, 0), "no week is in two quarters")
        let q3 = PlanQuarterWeeks.weekStarts(of: PlanQuarter(year: 2026, quarter: 3), calendar: calendar)
        #expect(q3.last.map { calendar.date(byAdding: .day, value: 7, to: $0) } == q4.first)
    }

    @Test("An objective is named by its words before a parenthesis, colon or dash")
    func objectiveNames() {
        #expect(PlanQuarterWeeks.objectiveName("Etcelera (the predictions handed over)") == "Etcelera")
        #expect(PlanQuarterWeeks.objectiveName("Talent Bridge: a biomarker of aging") == "Talent Bridge")
        #expect(PlanQuarterWeeks.objectiveName("Thesis — written by December") == "Thesis")
        #expect(PlanQuarterWeeks.objectiveName("Oxphos datasets") == "Oxphos datasets")
        let names = ["Lab", "Lab Bridge", "Thesis"]
        #expect(PlanQuarterWeeks.objectiveIndex(notes: "Serves Q4 objective: Lab Bridge.", names: names) == 1, "the longest name wins")
        #expect(PlanQuarterWeeks.objectiveIndex(notes: "serves the thesis", names: names) == 2)
        #expect(PlanQuarterWeeks.objectiveIndex(notes: "", names: names) == nil)
        #expect(PlanQuarterWeeks.objectiveIndex(notes: "an AB test", names: ["AB"]) == nil, "names under three letters never match")
    }

    @Test("Blocks fall on their days, and serve the quarter when they link its plan or name an objective")
    func weeksFromTheCalendar() throws {
        let calendar = PlanQuarterWeeks.weekCalendar(zone)
        let quarter = PlanQuarter(year: 2026, quarter: 4)
        let objectives = ["Lab (the predictions handed over)", "Thesis", "Bridge: candidate ideas"]
        let items = [
            PlanCalendarItem(key: "a", title: "Predictions", start: at(2026, 11, 9, 9), end: at(2026, 11, 9, 12),
                             notes: "Serves Q4 objective: Lab. Q4 plan: foreverlm://doc/plan-2026-q4", isMeeting: false),
            PlanCalendarItem(key: "b", title: "Sync", start: at(2026, 11, 9, 13), end: at(2026, 11, 9, 14),
                             notes: "Weekly Lab sync", isMeeting: true),
            PlanCalendarItem(key: "c", title: "Ideas", start: at(2026, 11, 10, 14, 30), end: at(2026, 11, 10, 17),
                             notes: "Q4 plan: foreverlm://doc/plan-2026-q4", isMeeting: false),
            PlanCalendarItem(key: "d", title: "Draft", start: at(2026, 11, 11, 9), end: at(2026, 11, 11, 10),
                             notes: "For the thesis", isMeeting: false),
            PlanCalendarItem(key: "e", title: "Dentist", start: at(2026, 11, 12, 9), end: at(2026, 11, 12, 10),
                             notes: "", isMeeting: false),
        ]
        let weeks = PlanQuarterWeeks.weeks(of: quarter, items: items, objectives: objectives, calendar: calendar)
        #expect(weeks.count == 14)
        let week = try #require(weeks.first { $0.start == at(2026, 11, 9, 0) })
        #expect(week.days.map(\.date) == ["2026-11-09", "2026-11-10", "2026-11-11", "2026-11-12", "2026-11-13", "2026-11-14", "2026-11-15"])
        #expect(week.days[0].blocks.map(\.id) == ["a", "b"])

        let monday = week.days[0].blocks
        #expect(monday[0].servesQuarter && monday[0].objective == 0)
        #expect(!monday[1].servesQuarter && monday[1].objective == nil, "a meeting is the week's ground, whatever its notes say")
        #expect(week.days[1].blocks[0].servesQuarter && week.days[1].blocks[0].objective == nil, "linking the plan is enough")
        #expect(week.days[2].blocks[0].objective == 1, "naming an objective is enough")
        #expect(!week.days[3].blocks[0].servesQuarter)

        #expect(week.plannedBlocks.map(\.id) == ["a", "c", "d"])
        #expect(week.plannedMinutes == 180 + 150 + 60)
        #expect(week.minutesByObjective == [0: 180, 1: 60])
        #expect(weeks.filter { $0.start != week.start }.allSatisfy { $0.plannedBlocks.isEmpty })
    }

    // MARK: The week's deliverables, in the quarter's Page

    private let deliverablesPlan = """
        ## Objectives

        - Lab: the predictions handed over
        - Thesis (written by December)
        - Lab Bridge: a project agreed

        ## Weeks

        ### Week of November 2
        - [x] Lab: last week's thing (Fri)

        ### Week of November 9
        - [ ] Lab: predictions handed over (Tue)
        - [x] Lab Bridge: one-page proposal sent — Thursday ^a1b2c3d4e
          - [ ] a sub-step, not a deliverable
        - a draft chapter for the thesis
        - [ ]
        - [ ] Something with no objective (by Friday)

        ## Notes

        - [ ] Lab: not in Weeks
        """

    @Test("A week's heading names its Monday, in the quarter's year, written several ways")
    func weekHeadings() {
        let calendar = PlanQuarterWeeks.weekCalendar(zone)
        let q4 = PlanQuarter(year: 2026, quarter: 4)
        let monday = at(2026, 11, 9, 0)
        #expect(PlanWeekDeliverables.heading(for: monday, calendar: calendar) == "Week of November 9")
        for heading in ["Week of November 9", "week of Nov 9th", "Week of November 9, 2026", "Week of 2026-11-09", "Week of November 11"] {
            #expect(PlanWeekDeliverables.monday(ofHeading: heading, quarter: q4, calendar: calendar) == monday, "\(heading)")
        }
        #expect(PlanWeekDeliverables.monday(ofHeading: "Week of December 29", quarter: PlanQuarter(year: 2026, quarter: 1), calendar: calendar)
            == at(2025, 12, 29, 0), "a December week read for Q1 is the year before")
        #expect(PlanWeekDeliverables.monday(ofHeading: "Notes", quarter: q4, calendar: calendar) == nil)
        #expect(PlanWeekDeliverables.monday(ofHeading: "Week of someday", quarter: q4, calendar: calendar) == nil)
    }

    @Test("The popover reads the week's top-level task lines, with their objective, day and tick")
    func weekDeliverables() {
        let calendar = PlanQuarterWeeks.weekCalendar(zone)
        let q4 = PlanQuarter(year: 2026, quarter: 4)
        let names = ["Lab", "Thesis", "Lab Bridge"]
        let items = PlanWeekDeliverables.deliverables(for: at(2026, 11, 9, 0), in: deliverablesPlan, quarter: q4, objectiveNames: names, calendar: calendar)
        #expect(items.map(\.text) == ["predictions handed over", "one-page proposal sent", "a draft chapter for the thesis", "Something with no objective"])
        #expect(items.map(\.objective) == [0, 2, 1, nil], "the opening name wins, longest first; else the name the line says")
        #expect(items.map(\.due) == ["Tue", "Thu", nil, "Fri"])
        #expect(items.map(\.isDone) == [false, true, false, false])
        #expect(PlanWeekDeliverables.deliverables(for: at(2026, 11, 16, 0), in: deliverablesPlan, quarter: q4, objectiveNames: names, calendar: calendar).isEmpty)
        #expect(PlanWeekDeliverables.deliverables(for: at(2026, 11, 2, 0), in: deliverablesPlan, quarter: q4, objectiveNames: names, calendar: calendar).map(\.text)
            == ["last week's thing"])
    }

    @Test("A tick changes only its own line's box, keeps the block id, and a plain bullet becomes a task")
    func tickingADeliverable() throws {
        let calendar = PlanQuarterWeeks.weekCalendar(zone)
        let q4 = PlanQuarter(year: 2026, quarter: 4)
        let monday = at(2026, 11, 9, 0)
        let names = ["Lab", "Thesis", "Lab Bridge"]
        let items = PlanWeekDeliverables.deliverables(for: monday, in: deliverablesPlan, quarter: q4, objectiveNames: names, calendar: calendar)

        let ticked = try #require(PlanWeekDeliverables.setting(items[0], done: true, weekOf: monday, in: deliverablesPlan, quarter: q4, calendar: calendar))
        #expect(ticked == deliverablesPlan.replacingOccurrences(of: "- [ ] Lab: predictions handed over (Tue)", with: "- [x] Lab: predictions handed over (Tue)"))
        #expect(ticked.contains("- [ ] Lab: not in Weeks"), "a line outside the week is never touched")

        let unticked = try #require(PlanWeekDeliverables.setting(items[1], done: false, weekOf: monday, in: deliverablesPlan, quarter: q4, calendar: calendar))
        #expect(unticked.contains("- [ ] Lab Bridge: one-page proposal sent — Thursday ^a1b2c3d4e"))

        let plain = try #require(PlanWeekDeliverables.setting(items[2], done: true, weekOf: monday, in: deliverablesPlan, quarter: q4, calendar: calendar))
        #expect(plain.contains("- [x] a draft chapter for the thesis"))

        let gone = deliverablesPlan.replacingOccurrences(of: "predictions handed over (Tue)", with: "predictions handed over (Wed)")
        #expect(PlanWeekDeliverables.setting(items[0], done: true, weekOf: monday, in: gone, quarter: q4, calendar: calendar) == nil,
                "a line rewritten meanwhile is not guessed at")
    }

    @Test("An objective named after another wears its colour; families take colours in order")
    func objectiveColorSlots() {
        #expect(PlanQuarterWeeks.colorSlots(["Lab", "Thesis", "Thesis Bridge", "Grant"]) == [0, 1, 1, 2])
        #expect(PlanQuarterWeeks.colorSlots(["Thesis Bridge", "Thesis"]) == [0, 0], "the family takes the colour its first member is given")
        #expect(PlanQuarterWeeks.colorSlots(["Thesis", "Thesis Bridge", "Thesis Bridge Pilot"]) == [0, 0, 0], "the shortest name is the family")
        #expect(PlanQuarterWeeks.colorSlots(["Lab", "Labrador"]) == [0, 1], "a name runs to a word boundary")
        #expect(PlanQuarterWeeks.colorSlots(["AB", "AB test"]) == [0, 1], "names under three letters make no family")
        #expect(PlanQuarterWeeks.colorSlots([]) == [])
    }

    @Test("Hours read short")
    func hoursText() {
        #expect(PlanQuarterWeeks.hoursText(45) == "45 min")
        #expect(PlanQuarterWeeks.hoursText(180) == "3 h")
        #expect(PlanQuarterWeeks.hoursText(150) == "2.5 h")
        #expect(PlanQuarterWeeks.hoursText(170) == "3 h")
    }
}
