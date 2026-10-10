import Foundation
import Testing
@testable import ForeverLM

/// The board logic behind a Notebook's Tasks page: grouping by status in a
/// stable order, the "Mine" filter, what counts as overdue at a chosen moment,
/// the status cycle and its completion stamp, and the due-date shortcuts.
@Suite("Notebook tasks board")
struct NotebookTasksBoardTests {
    private static let noon = Date(timeIntervalSince1970: 1_757_250_000) // 2025-09-07 12:20 UTC

    private static func task(
        _ title: String,
        status: NotebookTaskStatus = .todo,
        assignee: String? = nil,
        dueAt: Date? = nil,
        sortOrder: Double = 0,
        createdAt: Date = noon
    ) -> NotebookTaskRecord {
        NotebookTaskRecord(
            notebookID: "proj",
            title: title,
            status: status,
            assigneeRecordName: assignee,
            assigneeDisplayName: assignee,
            dueAt: dueAt,
            sortOrder: sortOrder,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }

    @Test("Sections follow board order and keep every status, empty or not")
    func sectionsInBoardOrder() {
        let tasks = [
            Self.task("done", status: .done),
            Self.task("todo"),
            Self.task("doing", status: .doing),
        ]
        let sections = NotebookTaskBoard.sections(tasks)
        #expect(sections.map(\.status) == [.todo, .doing, .done])
        #expect(sections.map { $0.tasks.map(\.title) } == [["todo"], ["doing"], ["done"]])

        let empty = NotebookTaskBoard.sections([])
        #expect(empty.map(\.status) == [.todo, .doing, .done])
        #expect(empty.allSatisfy { $0.tasks.isEmpty })
    }

    @Test("Within a section sortOrder wins and creation time breaks ties")
    func sectionOrdering() {
        let earlier = Self.noon.addingTimeInterval(-60)
        let tasks = [
            Self.task("third", sortOrder: 2),
            Self.task("second", sortOrder: 1, createdAt: Self.noon),
            Self.task("first", sortOrder: 1, createdAt: earlier),
        ]
        let todo = NotebookTaskBoard.sections(tasks).first { $0.status == .todo }
        #expect(todo?.tasks.map(\.title) == ["first", "second", "third"])
    }

    @Test("Mine keeps only the signed-in member's tasks, and nothing without a member")
    func mineFilter() {
        let tasks = [
            Self.task("mine", assignee: "me"),
            Self.task("theirs", assignee: "you"),
            Self.task("nobody's"),
        ]
        #expect(NotebookTaskBoard.filtered(tasks, mineOnly: false, currentUserRecordName: "me").count == 3)
        #expect(NotebookTaskBoard.filtered(tasks, mineOnly: true, currentUserRecordName: "me").map(\.title) == ["mine"])
        #expect(NotebookTaskBoard.filtered(tasks, mineOnly: true, currentUserRecordName: nil).isEmpty)
    }

    @Test("Overdue is a past due date on an unfinished task")
    func overdue() {
        let yesterday = Self.noon.addingTimeInterval(-86_400)
        let tomorrow = Self.noon.addingTimeInterval(86_400)
        #expect(NotebookTaskBoard.isOverdue(Self.task("late", dueAt: yesterday), now: Self.noon))
        #expect(!NotebookTaskBoard.isOverdue(Self.task("ahead", dueAt: tomorrow), now: Self.noon))
        #expect(!NotebookTaskBoard.isOverdue(Self.task("finished", status: .done, dueAt: yesterday), now: Self.noon))
        #expect(!NotebookTaskBoard.isOverdue(Self.task("undated"), now: Self.noon))
    }

    @Test("The status control cycles to do, in progress, done, and back")
    func statusCycle() {
        #expect(NotebookTaskBoard.next(after: .todo) == .doing)
        #expect(NotebookTaskBoard.next(after: .doing) == .done)
        #expect(NotebookTaskBoard.next(after: .done) == .todo)
    }

    @Test("Moving into Done stamps completion once; moving out clears it")
    func completionStamp() {
        let later = Self.noon.addingTimeInterval(600)
        let done = NotebookTaskBoard.changing(Self.task("t"), to: .done, now: Self.noon)
        #expect(done.status == .done)
        #expect(done.completedAt == Self.noon)

        let stillDone = NotebookTaskBoard.changing(done, to: .done, now: later)
        #expect(stillDone.completedAt == Self.noon)

        let reopened = NotebookTaskBoard.changing(done, to: .doing, now: later)
        #expect(reopened.status == .doing)
        #expect(reopened.completedAt == nil)
        #expect(reopened.updatedAt == later)
    }

    @Test("A new task lands after the last one")
    func nextSortOrder() {
        #expect(NotebookTaskBoard.nextSortOrder(after: []) == 1)
        #expect(NotebookTaskBoard.nextSortOrder(after: [Self.task("a", sortOrder: 3), Self.task("b", sortOrder: 7)]) == 8)
    }

    @Test("Due presets land in the last minute of their day")
    func duePresets() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Self.noon
        let today = try #require(NotebookTaskBoard.dueDate(for: .today, now: now, calendar: calendar))
        let tomorrow = try #require(NotebookTaskBoard.dueDate(for: .tomorrow, now: now, calendar: calendar))
        let nextWeek = try #require(NotebookTaskBoard.dueDate(for: .nextWeek, now: now, calendar: calendar))

        #expect(calendar.isDate(today, inSameDayAs: now))
        #expect(today > now)
        #expect(calendar.component(.hour, from: today) == 23)
        #expect(calendar.component(.minute, from: today) == 59)
        #expect(calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: tomorrow)).day == 1)
        #expect(calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: nextWeek)).day == 7)
        // Setting "Today" must not produce a task that is already overdue.
        #expect(!NotebookTaskBoard.isOverdue(Self.task("today", dueAt: today), now: now))
    }

    @Test("The inspector summary counts open tasks and the member's share of them")
    func openSummary() {
        let tasks = [
            Self.task("mine open", assignee: "me"),
            Self.task("mine done", status: .done, assignee: "me"),
            Self.task("theirs", status: .doing, assignee: "you"),
            Self.task("unassigned"),
        ]
        let summary = NotebookTaskBoard.openSummary(tasks, currentUserRecordName: "me")
        #expect(summary.open == 3)
        #expect(summary.mine == 1)
        let anonymous = NotebookTaskBoard.openSummary(tasks, currentUserRecordName: nil)
        #expect(anonymous.open == 3)
        #expect(anonymous.mine == 0)
    }

    @Test("A task links to one source or one Doc; the other side clears")
    func linking() {
        let bare = Self.task("bare")
        #expect(NotebookTaskBoard.link(of: bare) == nil)

        let later = Self.noon.addingTimeInterval(60)
        let onSource = NotebookTaskBoard.linking(bare, to: .source("src-1"), now: later)
        #expect(onSource.sourceID == "src-1")
        #expect(onSource.artifactID == nil)
        #expect(onSource.updatedAt == later)
        #expect(NotebookTaskBoard.link(of: onSource) == .source("src-1"))

        let onDoc = NotebookTaskBoard.linking(onSource, to: .doc("doc-1"), now: later)
        #expect(onDoc.sourceID == nil)
        #expect(onDoc.artifactID == "doc-1")
        #expect(NotebookTaskBoard.link(of: onDoc) == .doc("doc-1"))

        let cleared = NotebookTaskBoard.linking(onDoc, to: nil, now: later)
        #expect(cleared.sourceID == nil)
        #expect(cleared.artifactID == nil)
        #expect(NotebookTaskBoard.link(of: cleared) == nil)

        // A record that somehow carries both reads as its source.
        var both = bare
        both.sourceID = "src-2"
        both.artifactID = "doc-2"
        #expect(NotebookTaskBoard.link(of: both) == .source("src-2"))
    }
}
