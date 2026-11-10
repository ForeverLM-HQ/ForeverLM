import Foundation

// MARK: - A course and its notebooks (docs/courses-design.md, "A course is its own thing")
//
// A course is not part of a notebook: it is a structure over library sources
// that stands beside Notebooks, Collections and Artifacts (product owner,
// 2026-10-03: "courses should not be a part of notebooks; they are kind of
// separate entities"). Between the two there is one optional relation,
// `notebook_course_links` — "this notebook's sources follow the course":
// linking adds the course's current sources and every source it gains later.
// A notebook may follow any number of courses and a course may be followed by
// any number of notebooks; neither owns the other, and deleting a notebook
// leaves its courses as they were.

/// What making a study notebook for a course did.
struct CourseStudyNotebook: Equatable, Sendable {
    let courseID: String
    let notebookID: String
    /// False when the notebook already existed (made earlier, here or on
    /// another Mac, under the same fixed id) and was only linked again.
    let created: Bool
    /// How many of the course's sources joined the notebook's pool.
    let sourcesAdded: Int
}

/// Why a course could not be linked to a notebook, in two wordings of one
/// refusal: `errorDescription` says Notebook, as the MCP course tools read the
/// store; `learnerMessage` says notebook, as the app tells the learner.
enum CourseNotebookError: LocalizedError, Equatable {
    case courseNotFound(courseID: String)
    /// A team's course on a team this account can only read.
    case readOnlyTeamCourse(courseTitle: String)
    case notebookNotFound(notebookID: String)
    /// The course and the notebook are in different libraries (a team's and
    /// My Library, or two teams).
    case differentLibraries(courseTitle: String, notebookTitle: String)
    /// The notebook takes nothing new: archived, a read-only team's, a team
    /// not on this Mac (`NotebookImportRefusal.reason`).
    case notebookTakesNoCourse(notebookTitle: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .courseNotFound(let id): return "Course not found: \(id)"
        case .readOnlyTeamCourse(let course): return "‘\(course)’ is a team's course this account can only read."
        case .notebookNotFound(let id): return "Notebook not found: \(id)"
        case .differentLibraries(let course, let notebook):
            return "‘\(course)’ and ‘\(notebook)’ are in different libraries: a Notebook follows only a course of its own library."
        case .notebookTakesNoCourse(let notebook, let reason): return "‘\(notebook)’ takes no course, because \(reason)."
        }
    }

    /// The refusal as the learner reads it in the app.
    var learnerMessage: String {
        switch self {
        case .courseNotFound: return "That course is no longer in your library."
        case .readOnlyTeamCourse(let course): return "‘\(course)’ is a team's course you can only read."
        case .notebookNotFound: return "That notebook is no longer in your library."
        case .differentLibraries(let course, let notebook):
            return "‘\(course)’ and ‘\(NotebookTitle(notebook).text)’ are in different libraries: a notebook follows only a course of its own library."
        case .notebookTakesNoCourse(let notebook, let reason):
            return "‘\(NotebookTitle(notebook).text)’ takes no course, because \(reason)."
        }
    }

    /// What the app says for any failure to link a course: a refusal in the
    /// learner's words, anything else as it came.
    static func learnerMessage(for error: Error) -> String {
        (error as? CourseNotebookError)?.learnerMessage ?? error.localizedDescription
    }
}

extension KnowledgeStore {

    // MARK: - Reading

    /// Every notebook that follows a course (`notebook_course_links`).
    func notebookIDsFollowingCourse(_ courseID: String) throws -> [String] {
        var ids: [String] = []
        try queryBind(
            "SELECT goal_id FROM notebook_course_links WHERE course_id = ? ORDER BY goal_id",
            bind: { stmt in self.bind(stmt, 1, courseID) }
        ) { stmt in
            if let id = self.string(stmt, 0) { ids.append(id) }
        }
        return ids
    }

    /// Every course each notebook follows, keyed by course.
    func loadCourseFollowers() throws -> [String: [String]] {
        var result: [String: [String]] = [:]
        try query("SELECT course_id, goal_id FROM notebook_course_links ORDER BY course_id, goal_id") { stmt in
            guard let courseID = self.string(stmt, 0), let notebookID = self.string(stmt, 1) else { return }
            result[courseID, default: []].append(notebookID)
        }
        return result
    }

    // MARK: - Linking a course to a notebook

    /// The course's title and library (nil: My Library), refusing a course
    /// that is not here or a team's course this account can only read.
    private func editableCourseRow(_ courseID: String) throws -> (title: String, teamID: String?) {
        var row: (title: String, teamID: String?)?
        try queryBind("SELECT title, team_id FROM courses WHERE id = ? LIMIT 1", bind: { stmt in
            self.bind(stmt, 1, courseID)
        }) { stmt in
            row = (self.string(stmt, 0) ?? courseID, self.string(stmt, 1))
        }
        guard let row else { throw CourseNotebookError.courseNotFound(courseID: courseID) }
        if let teamID = row.teamID {
            guard let team = try loadTeam(teamID), team.canEdit else {
                throw CourseNotebookError.readOnlyTeamCourse(courseTitle: row.title)
            }
        }
        return row
    }

    /// Refuses a notebook that cannot follow a course of the library
    /// `courseTeamID` names: another library's, an archived one, a read-only
    /// team's, a team not on this Mac.
    private func requireNotebookMayFollow(_ notebook: LearningGoalRecord, courseTitle: String, courseTeamID: String?) throws {
        guard notebook.teamID == courseTeamID else {
            throw CourseNotebookError.differentLibraries(courseTitle: courseTitle, notebookTitle: notebook.title)
        }
        let team = try notebook.teamID.flatMap { try loadTeam($0) }
        if let refusal = NotebookImportRefusal.refusal(for: notebook, team: team) {
            throw CourseNotebookError.notebookTakesNoCourse(notebookTitle: notebook.title, reason: refusal.reason)
        }
    }

    /// The notebook follows the course, as the learner or a tool asked: it
    /// gains the course's sources now and every source the course gains later
    /// (`linkCourseToNotebook`). Refused for a notebook of another library, an
    /// archived notebook and a team this account can only read. Returns how
    /// many of the course's sources joined the notebook's pool.
    @discardableResult
    func followCourse(courseID rawCourseID: String, notebookID rawNotebookID: String) throws -> Int {
        let courseID = rawCourseID.trimmingCharacters(in: .whitespacesAndNewlines)
        let notebookID = rawNotebookID.trimmingCharacters(in: .whitespacesAndNewlines)
        let course = try editableCourseRow(courseID)
        guard let notebook = try loadLearningGoal(notebookID), notebook.isNotebook else {
            throw CourseNotebookError.notebookNotFound(notebookID: notebookID)
        }
        try requireNotebookMayFollow(notebook, courseTitle: course.title, courseTeamID: course.teamID)
        return try linkCourseToNotebook(goalID: notebookID, courseID: courseID, sourceIDs: [])
    }

    /// A notebook for studying a course, on the learner's ask: named after the
    /// course, holding its sources and following it, so a lecture the course
    /// gains joins it too. It has a fixed id per course
    /// (`TeamContentIdentity.courseNotebookID`), so two Macs asking make
    /// one, and a second ask only links again. The course itself stays what it
    /// was: nothing about it moves into the notebook.
    @discardableResult
    func makeStudyNotebook(courseID rawCourseID: String) throws -> CourseStudyNotebook {
        let courseID = rawCourseID.trimmingCharacters(in: .whitespacesAndNewlines)
        let course = try editableCourseRow(courseID)
        let notebookID = TeamContentIdentity.courseNotebookID(courseID: courseID)
        var created = false
        if let existing = try loadLearningGoal(notebookID) {
            guard existing.isNotebook else { throw CourseNotebookError.notebookNotFound(notebookID: notebookID) }
            try requireNotebookMayFollow(existing, courseTitle: course.title, courseTeamID: course.teamID)
        } else {
            let metadata = try loadCourseGroups()[courseID]
            let summary = [metadata?.institution, metadata?.instructors]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            _ = try createCompanionGoal(
                title: course.title,
                summary: summary.isEmpty ? nil : summary,
                topic: course.title,
                startAt: Date(),
                endAt: LearningGoalRecord.openEndedEndAt,
                dailyTarget: 3,
                discoveryEnabled: false,
                seedSourceIDs: [],
                teamID: course.teamID,
                id: notebookID
            )
            created = true
        }
        let added = try linkCourseToNotebook(goalID: notebookID, courseID: courseID, sourceIDs: [])
        return CourseStudyNotebook(courseID: courseID, notebookID: notebookID, created: created, sourcesAdded: added)
    }

    // MARK: - Notebook membership for a listing

    /// The notebook `notebookID` as `NotebookMembership` asks it: its approved
    /// pool, every Goal's Notebook, and for a team's notebook each team copy
    /// in its pool resolved to the learner's own row at the same address, so
    /// what rides the learner's source belongs to the team notebook holding
    /// its copy. Throws for an id that is not a Notebook.
    func notebookMembership(notebookID: String) throws -> NotebookMembership {
        guard let notebook = try loadLearningGoal(notebookID), notebook.isNotebook else {
            throw KnowledgeStoreError.invalidData("Notebook not found: \(notebookID)")
        }
        var goalParents: [String: String] = [:]
        for goal in try loadLearningGoals() {
            if let parent = goal.parentNotebookID { goalParents[goal.id] = parent }
        }
        var aliases: [String: String] = [:]
        if notebook.teamID != nil {
            for sourceID in notebook.approvedSourceIDs {
                guard let source = try loadSourceWithoutContent(sourceID), source.teamID != nil,
                      let own = activeSourceID(matchingAddress: source.url, teamID: nil), own != sourceID else { continue }
                aliases[sourceID] = own
            }
        }
        return NotebookMembership(
            notebookID: notebookID,
            memberSourceIDs: notebook.approvedSourceIDs,
            goalParents: goalParents,
            sourceAliases: aliases
        )
    }

    /// The courses a screen recording may show (`ScreenRecordScope.allowsCourse`): each course's
    /// followers and its lessons, read in two passes. The Courses list, its
    /// tab and the Add to Course menu narrow to these while the mode is on.
    func screenRecordShownCourseIDs(scope: ScreenRecordScope) throws -> Set<String> {
        let followers = try loadCourseFollowers()
        let shownLessons = try screenRecordCoursesWithShownLesson(scope: scope)
        var shown: Set<String> = []
        try query("SELECT id FROM courses") { stmt in
            guard let id = self.string(stmt, 0) else { return }
            if scope.allowsCourse(followedBy: followers[id] ?? [], hasShownLesson: shownLessons.contains(id)) {
                shown.insert(id)
            }
        }
        return shown
    }
}
