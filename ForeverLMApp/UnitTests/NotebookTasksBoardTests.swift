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

    // MARK: Moving a card

    private static func card(_ id: String, _ status: NotebookTaskStatus, order: Double) -> NotebookTaskRecord {
        NotebookTaskRecord(
            id: id, notebookID: "proj", title: id, status: status, sortOrder: order,
            // Distinct creation times, in id order, so a tie in `sortOrder` breaks the same way every run.
            createdAt: noon.addingTimeInterval(Double(id.unicodeScalars.first?.value ?? 0)), updatedAt: noon
        )
    }

    /// Applies the changes the way saving does, then reads a column back.
    private static func column(_ status: NotebookTaskStatus, after changes: [NotebookTaskRecord], of tasks: [NotebookTaskRecord]) -> [String] {
        var byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        for change in changes { byID[change.id] = change }
        return NotebookTaskBoard.sections(Array(byID.values)).first { $0.status == status }?.tasks.map(\.title) ?? []
    }

    @Test("A card dropped between two cards takes the midpoint and is the only one saved")
    func moveBetween() {
        let tasks = [Self.card("a", .todo, order: 1), Self.card("b", .todo, order: 2), Self.card("c", .doing, order: 1)]
        let changes = NotebookTaskBoard.moving(tasks[2], to: .todo, before: "b", among: tasks, now: Self.noon)
        #expect(changes.map(\.id) == ["c"])
        #expect(changes[0].sortOrder == 1.5)
        #expect(changes[0].status == .todo)
        #expect(Self.column(.todo, after: changes, of: tasks) == ["a", "c", "b"])
    }

    @Test("A card dropped on a column's head or foot goes before the first or after the last")
    func moveToEnds() {
        let tasks = [Self.card("a", .todo, order: 1), Self.card("b", .todo, order: 2), Self.card("c", .doing, order: 1)]
        let top = NotebookTaskBoard.moving(tasks[2], to: .todo, before: "a", among: tasks, now: Self.noon)
        #expect(Self.column(.todo, after: top, of: tasks) == ["c", "a", "b"])
        let bottom = NotebookTaskBoard.moving(tasks[2], to: .todo, before: nil, among: tasks, now: Self.noon)
        #expect(Self.column(.todo, after: bottom, of: tasks) == ["a", "b", "c"])
        let empty = NotebookTaskBoard.moving(tasks[0], to: .done, before: nil, among: tasks, now: Self.noon)
        #expect(empty.map(\.status) == [.done])
        #expect(empty[0].completedAt == Self.noon)
    }

    @Test("Reordering inside a column keeps its status, and dropping a card where it is changes nothing")
    func moveWithinColumn() {
        let tasks = [Self.card("a", .todo, order: 1), Self.card("b", .todo, order: 2), Self.card("c", .todo, order: 3)]
        let changes = NotebookTaskBoard.moving(tasks[2], to: .todo, before: "a", among: tasks, now: Self.noon)
        #expect(Self.column(.todo, after: changes, of: tasks) == ["c", "a", "b"])
        #expect(NotebookTaskBoard.moving(tasks[1], to: .todo, before: "c", among: tasks, now: Self.noon).isEmpty)
        #expect(NotebookTaskBoard.moving(tasks[1], to: .todo, before: "b", among: tasks, now: Self.noon).isEmpty)
        #expect(NotebookTaskBoard.moving(tasks[2], to: .todo, before: nil, among: tasks, now: Self.noon).isEmpty)
    }

    @Test("Tied neighbours renumber the column instead of guessing an order")
    func moveAmongTies() {
        let tasks = [
            Self.card("a", .todo, order: 1), Self.card("b", .todo, order: 1),
            Self.card("c", .todo, order: 1), Self.card("d", .doing, order: 1),
        ]
        let changes = NotebookTaskBoard.moving(tasks[3], to: .todo, before: "b", among: tasks, now: Self.noon)
        #expect(Self.column(.todo, after: changes, of: tasks) == ["a", "d", "b", "c"])
    }

    // MARK: The day's plan

    private static func finished(_ title: String, at completedAt: Date, dueAt: Date? = nil) -> NotebookTaskRecord {
        var task = Self.task(title, status: .done, dueAt: dueAt)
        task.completedAt = completedAt
        return task
    }

    @Test("Today keeps what is under way, what is due by tonight and what was finished today")
    func todayLens() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let startOfDay = calendar.startOfDay(for: Self.noon)
        let tonight = startOfDay.addingTimeInterval(86_400 - 60)
        let tasks = [
            Self.task("later", dueAt: tonight.addingTimeInterval(86_400)),
            Self.task("undated"),
            Self.task("due today", dueAt: tonight),
            Self.task("overdue", dueAt: startOfDay.addingTimeInterval(-86_400)),
            Self.task("doing", status: .doing),
            Self.finished("done today", at: Self.noon),
            Self.finished("done last week", at: startOfDay.addingTimeInterval(-7 * 86_400), dueAt: tonight),
            Self.task("done, never stamped", status: .done),
        ]
        let today = NotebookTaskBoard.lensed(tasks, .today, now: Self.noon, calendar: calendar)
        #expect(Set(today.map(\.title)) == ["due today", "overdue", "doing", "done today"])
        #expect(NotebookTaskBoard.lensed(tasks, .all, now: Self.noon, calendar: calendar).count == tasks.count)
    }

    @Test("Search keeps cards whose title or notes hold every word")
    func searching() {
        var notes = Self.task("Ship invoice export")
        notes.notes = "waiting on Zara Holt"
        let tasks = [notes, Self.task("Write release notes")]
        #expect(NotebookTaskBoard.matching(tasks, query: "").count == 2)
        #expect(NotebookTaskBoard.matching(tasks, query: "invoice").map(\.title) == ["Ship invoice export"])
        #expect(NotebookTaskBoard.matching(tasks, query: "zara export").map(\.title) == ["Ship invoice export"])
        #expect(NotebookTaskBoard.matching(tasks, query: "invoice release").isEmpty)
    }

    // MARK: The Board's own lists

    private static let lists = [
        NotebookTaskList(id: "bl_b", notebookID: "proj", title: "Waiting", orderKey: "a1"),
        NotebookTaskList(id: "bl_a", notebookID: "proj", title: "Reading", orderKey: "a0"),
    ]

    @Test("Lists sit between In progress and Done in key order, and only open cards of a list still there are in it")
    func listColumns() {
        var listed = Self.card("a", .todo, order: 1)
        listed.listID = "bl_a"
        var finished = Self.card("b", .done, order: 1)
        finished.listID = "bl_a"
        var orphan = Self.card("c", .todo, order: 2)
        orphan.listID = "bl_gone"
        let sections = NotebookTaskBoard.sections([listed, finished, orphan], lists: Self.lists)
        #expect(sections.map(\.title) == ["To do", "In progress", "Reading", "Waiting", "Done"])
        #expect(sections[2].tasks.map(\.id) == ["a"])
        #expect(sections[0].tasks.map(\.id) == ["c"])
        #expect(sections[4].tasks.map(\.id) == ["b"])
        #expect(sections[2].status == .todo, "a list is open")
    }

    @Test("A card dragged into a list is open in it; dragged out, it leaves the list; its circle finishes it")
    func movingIntoAndOutOfLists() {
        let tasks = [Self.card("a", .doing, order: 1), Self.card("b", .todo, order: 1)]
        let into = NotebookTaskBoard.moving(tasks[0], into: .list("bl_a"), before: nil, among: tasks, lists: Self.lists, now: Self.noon)
        #expect(into.count == 1 && into[0].listID == "bl_a" && into[0].status == .todo && into[0].completedAt == nil)
        let inList = into[0]
        let out = NotebookTaskBoard.moving(inList, into: .status(.todo), before: "b", among: [inList, tasks[1]], lists: Self.lists, now: Self.noon)
        #expect(out.count == 1 && out[0].listID == nil && out[0].status == .todo)
        #expect(NotebookTaskBoard.next(for: inList, inList: true) == .done)
        let done = NotebookTaskBoard.changing(inList, to: .done, now: Self.noon)
        #expect(done.listID == nil && done.status == .done)
        #expect(NotebookTaskBoard.moving(inList, into: .list("bl_a"), before: nil, among: [inList], lists: Self.lists, now: Self.noon).isEmpty,
                "dropped where it is")
    }

    @Test("A card taken into a chat reads as its title, its notes and a request")
    func boardCardChatDraftReadsAsTheCard() {
        let bare = Self.task("  Why do bats not get cancer?  ")
        #expect(StudioViewModel.boardCardChatDraft(bare)
            == "I had this idea: \u{201C}Why do bats not get cancer?\u{201D}\n\nHelp me think it through.")

        var noted = Self.task("Bats")
        noted.notes = "\n Long-lived, high metabolism. \n"
        #expect(StudioViewModel.boardCardChatDraft(noted)
            == "I had this idea: \u{201C}Bats\u{201D}\n\nLong-lived, high metabolism.\n\nHelp me think it through.")
    }

    @Test("A card carries the chat it was taken into")
    func cardCarriesItsChat() {
        var card = Self.task("Bats")
        #expect(card.chatID == nil)
        card.chatID = "chat-1"
        #expect(card.chatID == "chat-1")
    }
}
