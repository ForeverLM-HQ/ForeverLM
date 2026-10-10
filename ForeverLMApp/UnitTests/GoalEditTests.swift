import Foundation
import Testing
@testable import ForeverLM

/// What a save from the Goal editor writes (product owner, 2026-09-20, on a click
/// opening a "What is this goal for?" picker: "this seems very poorly
/// designed"). See `GoalEdit` in GoalEditorSheet.swift.
@Suite("Goal edit")
struct GoalEditTests {
    private let calendar = Calendar(identifier: .gregorian)

    private func goal(
        title: String = "Understand pooled in vivo screening",
        endAt: Date,
        parentNotebookID: String? = nil,
        artifactID: String? = nil
    ) -> LearningGoalRecord {
        var record = LearningGoalRecord(
            id: "goal-1",
            title: title,
            startAt: endAt.addingTimeInterval(-7 * 86_400),
            endAt: endAt,
            createdAt: endAt.addingTimeInterval(-7 * 86_400),
            updatedAt: endAt.addingTimeInterval(-7 * 86_400),
            status: "active",
            items: []
        )
        record.kind = LearningGoalRecord.companionKind
        record.parentNotebookID = parentNotebookID
        record.artifactID = artifactID
        return record
    }

    private var sunday: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 27))!
    }

    @Test("An editor opened and saved untouched writes nothing")
    func untouchedIsEmpty() {
        let record = goal(endAt: sunday, parentNotebookID: "notebook-1", artifactID: "site-1")
        let edit = GoalEdit(goal: record)
        #expect(edit.changes(from: record, calendar: calendar).isEmpty)
    }

    @Test("The title is trimmed, and a blank one is not a change")
    func title() {
        let record = goal(endAt: sunday)
        var edit = GoalEdit(goal: record)
        edit.title = "  Understand pooled in vivo screening  "
        #expect(edit.changes(from: record, calendar: calendar).isEmpty, "whitespace around the same words is no change")

        edit.title = "Understand pooled in vivo screening, and its costs "
        #expect(edit.changes(from: record, calendar: calendar).title == "Understand pooled in vivo screening, and its costs")

        edit.title = "   "
        #expect(edit.changes(from: record, calendar: calendar).title == nil, "a blank title is never written")
    }

    @Test("A deadline moved within its own day is unchanged; a new day is stored at its start")
    func deadline() {
        let record = goal(endAt: sunday)
        var edit = GoalEdit(goal: record)
        edit.deadline = sunday.addingTimeInterval(15 * 3_600)
        #expect(edit.changes(from: record, calendar: calendar).deadline == nil)

        let wednesday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 11))!
        edit.deadline = wednesday
        #expect(edit.changes(from: record, calendar: calendar).deadline == calendar.startOfDay(for: wednesday))
    }

    @Test("Untagging a Notebook and unlinking an artifact are written as explicit clears")
    func clears() {
        let record = goal(endAt: sunday, parentNotebookID: "notebook-1", artifactID: "site-1")
        var edit = GoalEdit(goal: record)
        edit.notebookID = nil
        edit.artifactID = ""
        let changes = edit.changes(from: record, calendar: calendar)
        #expect(changes.retagsNotebook)
        #expect(changes.notebookID == nil)
        #expect(changes.relinksArtifact)
        #expect(changes.artifactID == nil)
        #expect(!changes.isEmpty)
    }

    @Test("The chat's opening line names the goal, when it is due, and what the sources are for")
    func chatDraft() {
        let today = calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 9))!
        var record = goal(endAt: sunday)
        #expect(
            StudioViewModel.goalChatDraft(record, now: today, calendar: calendar, locale: Locale(identifier: "en_GB"))
                == "I'm working on my goal “Understand pooled in vivo screening”, due Sunday 27 September (7 days away). Help me work out where to start."
        )

        func item(_ sourceID: String, _ state: LearningGoalItemReviewState) -> LearningGoalItem {
            LearningGoalItem(id: "item-\(sourceID)", goalID: record.id, sourceID: sourceID, addedAt: today, reviewState: state.rawValue)
        }
        record.items = [item("a", .approved), item("b", .approved), item("c", .pending)]
        #expect(StudioViewModel.goalChatDraft(record, now: today, calendar: calendar, locale: Locale(identifier: "en_GB")).hasSuffix("Help me make progress on it with the 2 sources in context."))

        record.endAt = calendar.date(from: DateComponents(year: 2026, month: 9, day: 14))!
        #expect(StudioViewModel.goalChatDraft(record, now: today, calendar: calendar, locale: Locale(identifier: "en_GB")).contains(", which was due Monday 14 September."))

        record.endAt = calendar.startOfDay(for: today)
        #expect(StudioViewModel.goalChatDraft(record, now: today, calendar: calendar, locale: Locale(identifier: "en_GB")).contains(", due today."))
    }

    @Test("The deadline badge shows only while it asks for something; otherwise the date says it")
    func badgeAsksOrStaysQuiet() {
        let now = sunday.addingTimeInterval(9 * 3_600)
        func badge(_ record: LearningGoalRecord, filmsNoWarnings: Bool = false) -> String? {
            GoalStatusBadge.descriptor(for: record, asOf: now, calendar: calendar, filmsNoWarnings: filmsNoWarnings)?.text
        }
        func days(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: sunday)! }

        #expect(badge(goal(endAt: days(12))) == nil, "twelve days out is the date alone")
        #expect(badge(goal(endAt: days(4))) == nil)
        #expect(badge(goal(endAt: days(3))) == "3 days left")
        #expect(badge(goal(endAt: days(1))) == "1 day left")
        #expect(badge(goal(endAt: sunday)) == "Due today")
        #expect(badge(goal(endAt: days(-2))) == "Overdue by 2 days")
        #expect(badge(goal(endAt: days(-2)), filmsNoWarnings: true) == nil, "Screen record mode films no warning")

        var done = goal(endAt: days(12))
        done.status = LearningGoalStatus.done.rawValue
        #expect(badge(done) == "Done")
        var archived = goal(endAt: days(-2))
        archived.status = LearningGoalStatus.archived.rawValue
        #expect(badge(archived) == "Archived")
    }

    @Test("Tagging and linking carry the ids; an explicit-unlink record reads as unlinked")
    func links() {
        let record = goal(endAt: sunday, artifactID: "")
        var edit = GoalEdit(goal: record)
        #expect(edit.artifactID == nil, "the stored \"\" is no artifact, the way the row reads it")

        edit.notebookID = " notebook-2 "
        edit.artifactID = "doc-9"
        let changes = edit.changes(from: record, calendar: calendar)
        #expect(changes.notebookID == "notebook-2")
        #expect(changes.artifactID == "doc-9")
        #expect(changes.title == nil)
        #expect(changes.deadline == nil)
    }
}
