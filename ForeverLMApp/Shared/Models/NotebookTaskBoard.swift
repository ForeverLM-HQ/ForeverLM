import Foundation

/// The arithmetic behind a Notebook's task board, kept apart from the view so
/// it can be tested without one: how tasks group by status, which of them are
/// the signed-in member's, what "overdue" means at a given moment, and the
/// dates the due-date shortcuts stand for.
enum NotebookTaskBoard {
    struct Section: Equatable {
        let status: NotebookTaskStatus
        let tasks: [NotebookTaskRecord]
    }

    /// One section per status, in board order, each sorted by `sortOrder`
    /// with creation time breaking ties so two tasks added in a row keep the
    /// order they were typed in. Empty sections are kept: the board decides
    /// whether to draw them.
    static func sections(_ tasks: [NotebookTaskRecord]) -> [Section] {
        NotebookTaskStatus.allCases.map { status in
            let members = tasks
                .filter { $0.status == status }
                .sorted {
                    if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                    return $0.createdAt < $1.createdAt
                }
            return Section(status: status, tasks: members)
        }
    }

    /// The "Mine" filter. With no signed-in member to compare against (My
    /// Library, or a team whose roster has not arrived) nothing is mine, so
    /// the filter empties the board rather than quietly showing everything.
    static func filtered(
        _ tasks: [NotebookTaskRecord],
        mineOnly: Bool,
        currentUserRecordName: String?
    ) -> [NotebookTaskRecord] {
        guard mineOnly else { return tasks }
        guard let currentUserRecordName else { return [] }
        return tasks.filter { $0.assigneeRecordName == currentUserRecordName }
    }

    /// Overdue means a due date in the past on a task that is not done.
    /// `NotebookTaskRecord.isOverdue` reads the clock; this takes it as an
    /// argument so a test can stand at a chosen moment.
    static func isOverdue(_ task: NotebookTaskRecord, now: Date) -> Bool {
        guard task.status != .done, let dueAt = task.dueAt else { return false }
        return dueAt < now
    }

    /// The status a click on the row's status control moves to. Done wraps
    /// back to To do so a task ticked by mistake can be reopened with one more
    /// click instead of a menu trip.
    static func next(after status: NotebookTaskStatus) -> NotebookTaskStatus {
        switch status {
        case .todo: return .doing
        case .doing: return .done
        case .done: return .todo
        }
    }

    /// A copy of the task in the new status. Moving into Done stamps the
    /// completion time; moving out of it clears the stamp so a reopened task
    /// does not claim to have finished before it did.
    static func changing(_ task: NotebookTaskRecord, to status: NotebookTaskStatus, now: Date = Date()) -> NotebookTaskRecord {
        var changed = task
        changed.status = status
        changed.completedAt = status == .done ? (task.completedAt ?? now) : nil
        changed.updatedAt = now
        return changed
    }

    /// A new task lands at the bottom of its board.
    static func nextSortOrder(after tasks: [NotebookTaskRecord]) -> Double {
        (tasks.map(\.sortOrder).max() ?? 0) + 1
    }

    /// What a task is about: one of the Notebook's sources or one of its Docs.
    /// A task points at one thing at most; the record keeps two columns so a
    /// source id and a Doc id never have to share a namespace.
    enum Link: Equatable {
        case source(String)
        case doc(String)
    }

    /// The task's link, reading the source first where a record somehow
    /// carries both.
    static func link(of task: NotebookTaskRecord) -> Link? {
        if let sourceID = task.sourceID { return .source(sourceID) }
        if let artifactID = task.artifactID { return .doc(artifactID) }
        return nil
    }

    /// A copy of the task pointing at `link`, or at nothing. Setting one side
    /// clears the other, so a task moved from a source to a Doc does not keep
    /// quietly pointing at the source too.
    static func linking(_ task: NotebookTaskRecord, to link: Link?, now: Date = Date()) -> NotebookTaskRecord {
        var changed = task
        switch link {
        case .source(let id):
            changed.sourceID = id
            changed.artifactID = nil
        case .doc(let id):
            changed.sourceID = nil
            changed.artifactID = id
        case nil:
            changed.sourceID = nil
            changed.artifactID = nil
        }
        changed.updatedAt = now
        return changed
    }

    enum DuePreset: CaseIterable {
        case today
        case tomorrow
        case nextWeek

        var title: String {
            switch self {
            case .today: return "Today"
            case .tomorrow: return "Tomorrow"
            case .nextWeek: return "Next week"
            }
        }
    }

    /// The moment a preset stands for: the last minute of that day, so a task
    /// due "Today" is not overdue the instant it is set.
    static func dueDate(for preset: DuePreset, now: Date, calendar: Calendar = .current) -> Date? {
        let offsetDays: Int
        switch preset {
        case .today: offsetDays = 0
        case .tomorrow: offsetDays = 1
        case .nextWeek: offsetDays = 7
        }
        guard let day = calendar.date(byAdding: .day, value: offsetDays, to: calendar.startOfDay(for: now)),
              let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
        return nextDay.addingTimeInterval(-60)
    }

    /// The task count a row summarizes: everything still open, and how many
    /// of those are the signed-in member's.
    static func openSummary(_ tasks: [NotebookTaskRecord], currentUserRecordName: String?) -> (open: Int, mine: Int) {
        let open = tasks.filter { $0.status != .done }
        let mine = currentUserRecordName.map { me in open.filter { $0.assigneeRecordName == me }.count } ?? 0
        return (open.count, mine)
    }
}
