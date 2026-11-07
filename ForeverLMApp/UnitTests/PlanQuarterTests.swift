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
            == ["## Big picture", "## Objectives", "## Strategies and habits"])
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
}
