import Foundation

/// A course lecture item resolved to the source it points at, paired with the
/// lecture it belongs to.
struct CoursePathItem: Identifiable {
    let lecture: CourseSession
    let item: CourseLectureItem
    let article: StudioArticle
    var id: String { item.id }
}

/// How a quiz row names its quiz, and what taking it opens.
struct CourseQuizTarget: Equatable {
    let quizID: String
    /// "Quiz", "Quiz 2", "Course test", or the topics the quiz covers.
    let title: String
    /// The lecture's title, the lectures covered, or the course's title.
    let subtitle: String
    /// The lecture video a practice quiz's pre-storage score was kept under.
    let legacyVideoSourceID: String?
}

/// One row of a course's path, in the order the course page lists it.
struct CoursePathEntry: Identifiable {
    enum Kind {
        /// A lecture video, with the title its row shows.
        case video(CoursePathItem, displayTitle: String)
        /// A textbook reading after its lecture.
        case reading(StudioViewModel.CourseTextbookReading)
        /// Assigned reading (a paper) or the notes, slides or problem set
        /// filed under the lecture.
        case material(CoursePathItem)
        /// A written quiz and how its row names it.
        case quiz(CourseQuizTarget, CourseQuiz)
    }

    let id: String
    let kind: Kind

    /// The source the row opens, for everything but a quiz.
    var sourceID: String? {
        switch kind {
        case .video(let row, _), .material(let row): return row.article.id
        case .reading(let reading): return reading.chapter.id
        case .quiz: return nil
        }
    }

    var quiz: CourseQuiz? {
        if case .quiz(_, let quiz) = kind { return quiz }
        return nil
    }
}

extension CoursePathEntry: CourseGateStep {
    var gatingQuizID: String? { quiz?.id }
}

/// A lecture and the rows under it: the unit the course page draws as one
/// card, Khan Academy's lesson with its practice.
struct CourseUnit: Identifiable {
    let lecture: CourseSession
    /// The lecture's title, without its number.
    let title: String
    let entries: [CoursePathEntry]
    var id: String { lecture.id }
}

/// The course page's blocks in order: a unit per lecture, with the checkpoint
/// quizzes and the course test standing between and after them.
enum CoursePathBlock: Identifiable {
    case unit(CourseUnit)
    case milestone(CoursePathEntry)

    var id: String {
        switch self {
        case .unit(let unit): return "unit-\(unit.id)"
        case .milestone(let entry): return entry.id
        }
    }
}

/// A course as its page lists it (docs/courses-design.md).
struct CoursePath {
    let courseID: String
    let blocks: [CoursePathBlock]
    /// Course material no lecture claims, closing the page as further reading.
    let furtherMaterial: [StudioArticle]

    /// Every row in path order: each unit's rows, then the milestone after it.
    var entries: [CoursePathEntry] {
        blocks.flatMap { block -> [CoursePathEntry] in
            switch block {
            case .unit(let unit): return unit.entries
            case .milestone(let entry): return [entry]
            }
        }
    }
}

/// A lecture the course's gate holds back, as the video player reports it
/// when a playlist or YouTube's autoplay hands the player on to it.
struct CourseLock: Equatable {
    let courseID: String
    let quizID: String
    /// The quiz as its row names it.
    let quizTitle: String
}

extension StudioViewModel {

    /// The course's path in page order (docs/courses-design.md): each lecture's
    /// videos, then its readings — papers assigned as reading, then textbook
    /// sections — and the notes, slides or problem sets filed under it, then
    /// its practice quiz once written; a checkpoint quiz or the course test
    /// stands after the lecture it follows. Quizzes whose lectures are gone
    /// end the path. A paper a lecture's video only cites is not on the path:
    /// it opens from the video's Papers menu (`lectureVideoPapers`).
    func coursePath(for courseID: String) -> CoursePath {
        let lectures = courseLectures(for: courseID)
        // A quiz with no questions has nothing to take, so it gets no row.
        let placements = CourseQuizPlanning.placements(
            quizzes: courseQuizzes(for: courseID).filter { !$0.questions.isEmpty },
            lectureOrder: lectures.map(\.id)
        )
        let numberByLecture = Dictionary(lectures.map { ($0.id, $0.number) }, uniquingKeysWith: { first, _ in first })
        let courseTitle = courseDisplayName(courseID)
        var blocks: [CoursePathBlock] = []

        func quizEntry(_ quiz: CourseQuiz, lectureTitle: String?, legacyVideoSourceID: String?) -> CoursePathEntry {
            let numbers = quiz.lectureIDs.compactMap { numberByLecture[$0] }.sorted()
            let subtitle: String
            switch quiz.kind {
            case .practice:
                subtitle = lectureTitle
                    ?? (quiz.title.hasPrefix("Quiz: ") ? String(quiz.title.dropFirst(6)) : quiz.title)
            case .checkpoint:
                if let first = numbers.first, let last = numbers.last {
                    subtitle = first == last ? "Lecture \(first)" : "Lectures \(first)–\(last)"
                } else {
                    subtitle = courseTitle
                }
            case .test:
                subtitle = courseTitle
            }
            let target = CourseQuizTarget(
                quizID: quiz.id,
                title: quiz.kind == .practice && !quiz.hasTopicTitle ? "Quiz" : quiz.title,
                subtitle: subtitle,
                legacyVideoSourceID: legacyVideoSourceID
            )
            return CoursePathEntry(id: "quiz-\(quiz.id)", kind: .quiz(target, quiz))
        }

        for lecture in lectures {
            let citedOnly = Set(lectureVideoPapers(for: lecture.id).map(\.item.id))
            var videos: [CoursePathItem] = []
            var papers: [CoursePathItem] = []
            var materials: [CoursePathItem] = []
            for item in courseLectureItems(for: lecture.id) where !citedOnly.contains(item.id) {
                guard let article = article(for: item) else { continue }
                let row = CoursePathItem(lecture: lecture, item: item, article: article)
                // Paper identity is the source type, not the item's role:
                // older associations use `reading`, and a paper stays a paper
                // when a caller attached it as `reference` or `other`.
                if article.sourceType == .paper {
                    papers.append(row)
                } else if item.role == .video {
                    videos.append(row)
                } else if item.role == .reading, article.sourceType == .book {
                    // A textbook reading, listed through `textbookReadings`.
                    continue
                } else {
                    materials.append(row)
                }
            }

            var entries: [CoursePathEntry] = []
            var lectureTitle = lecture.title.map { courseMaterialDisplayTitle($0, courseID: courseID) }
            for row in videos {
                let displayTitle = Self.courseLectureRowTitle(
                    lectureNumber: lecture.number,
                    lectureTitle: lecture.title.map { courseMaterialDisplayTitle($0, courseID: courseID) },
                    itemTitle: courseMaterialDisplayTitle(row.article.title, courseID: courseID)
                )
                if lectureTitle == nil || lectureTitle?.isEmpty == true {
                    lectureTitle = courseMaterialDisplayTitle(row.article.title, courseID: courseID)
                }
                entries.append(CoursePathEntry(id: "video-\(row.id)", kind: .video(row, displayTitle: displayTitle)))
            }
            for row in papers {
                entries.append(CoursePathEntry(id: "material-\(row.id)", kind: .material(row)))
            }
            for reading in textbookReadings(for: lecture.id) {
                entries.append(CoursePathEntry(id: "reading-\(reading.id)", kind: .reading(reading)))
            }
            for row in materials {
                entries.append(CoursePathEntry(id: "material-\(row.id)", kind: .material(row)))
            }

            let placed = placements.afterLecture[lecture.id] ?? []
            let practiceID = CourseQuizPlanning.practiceID(courseID: courseID, lectureID: lecture.id)
            // An unwritten practice quiz has no row at all (product owner,
            // 2026-09-26: quizzes show only once generated).
            if let practice = placed.first(where: { $0.id == practiceID }) {
                entries.append(quizEntry(
                    practice,
                    lectureTitle: lectureTitle ?? "Lecture \(lecture.number)",
                    legacyVideoSourceID: videos.first?.article.id
                ))
            }
            let title = Self.stripDanglingLectureSeparators(Self.strippedLeadingLectureOrdinal(
                lectureTitle ?? ""
            ))
            blocks.append(.unit(CourseUnit(
                lecture: lecture,
                title: title.isEmpty ? "Lecture \(lecture.number)" : title,
                entries: entries
            )))
            for quiz in placed where quiz.id != practiceID {
                blocks.append(.milestone(quizEntry(quiz, lectureTitle: nil, legacyVideoSourceID: nil)))
            }
        }
        for quiz in placements.atEnd {
            blocks.append(.milestone(quizEntry(quiz, lectureTitle: nil, legacyVideoSourceID: nil)))
        }
        return CoursePath(
            courseID: courseID,
            blocks: blocks,
            furtherMaterial: unassignedCourseArticles(for: courseID)
        )
    }

    /// A course material's title as the course page shows it.
    func courseMaterialDisplayTitle(_ title: String, courseID: String) -> String {
        let original = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var cleaned = original
        for courseTitle in [courseID, courseDisplayName(courseID)] {
            guard !courseTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            cleaned = Self.playlistSourceDisplayTitle(
                originalTitle: cleaned,
                cleanedLectureTitle: cleaned,
                courseName: courseTitle
            )
        }
        return cleaned.isEmpty ? original : cleaned
    }

    /// A lecture title without the number a playlist put in front of it
    /// ("5) Isolated Mitochondria" reads "Isolated Mitochondria" under a unit
    /// headed Lecture 5).
    nonisolated static func strippedLeadingLectureOrdinal(_ title: String) -> String {
        guard let range = leadingLectureOrdinalRange(in: title) else { return title }
        return String(title[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a row of the path is done: a video watched to the end, a
    /// reading or material read or reviewed, or a quiz sitting completed.
    func isCoursePathEntryFinished(_ entry: CoursePathEntry) -> Bool {
        switch entry.kind {
        case .video(let row, _), .material(let row):
            return isCourseSourceFinished(row.article)
        case .reading(let reading):
            return isTextbookReadingFinished(reading)
        case .quiz(let target, _):
            return isCourseQuizCompleted(target.quizID, legacyVideoSourceID: target.legacyVideoSourceID)
        }
    }

    /// Whether a row of the path can be done at all: a video can be watched,
    /// a reading read to its last page, a quiz completed, and a paper or web
    /// article marked read. A course's own PDF or a lesson sheet can only be
    /// reviewed (`isCoursePathEntryFinished` still counts that), so until it
    /// is, it has no done state for Continue to wait on.
    func coursePathEntryHasDoneState(_ entry: CoursePathEntry) -> Bool {
        switch entry.kind {
        case .video, .reading, .quiz:
            return true
        case .material(let row):
            return row.article.sourceType == .video || row.article.cachedSupportsReadTracking
        }
    }

    /// Watched to the end, marked read, or reviewed — what `courseProgress`
    /// counts as finished.
    func isCourseSourceFinished(_ article: StudioArticle) -> Bool {
        let watched = readingProgressStore.videoWatchProgress(
            for: article.id,
            fallbackLocator: article.readingPositionLocator
        )?.isEssentiallyWatched == true
        return watched || article.isRead || sourceReviewedAt[article.id] != nil
    }

    /// Whether a row of the path has been begun: a saved position, or any
    /// sitting of a quiz.
    func isCoursePathEntryStarted(_ entry: CoursePathEntry) -> Bool {
        switch entry.kind {
        case .video(let row, _), .material(let row):
            return readingProgressStore.hasProgress(for: row.article.id) || row.article.hasSavedReadingPosition
        case .reading(let reading):
            return readingProgressStore.hasProgress(for: reading.chapter.id) || reading.chapter.hasSavedReadingPosition
        case .quiz(let target, _):
            return courseQuizScore(quizID: target.quizID, legacyVideoSourceID: target.legacyVideoSourceID) != nil
                || courseQuizSittings[target.quizID]?.isUnderWay == true
        }
    }

    /// Whether the quiz has a finished sitting. Completion opens the course;
    /// the score still says separately whether the sitting passed.
    func isCourseQuizCompleted(_ quizID: String, legacyVideoSourceID: String? = nil) -> Bool {
        courseQuizScore(quizID: quizID, legacyVideoSourceID: legacyVideoSourceID) != nil
    }

    /// Whether a sitting of the quiz has passed (`LectureQuizScore.hasPassed`).
    func isCourseQuizPassed(_ quizID: String, legacyVideoSourceID: String? = nil) -> Bool {
        courseQuizScore(quizID: quizID, legacyVideoSourceID: legacyVideoSourceID)?.hasPassed == true
    }

    /// The gate over a course's path.
    func courseGate(for path: CoursePath) -> CourseGate {
        // Positions are unobserved; this re-renders the page when a lecture finishes.
        _ = readingProgressStore.finishedVideoRevision
        return CourseGate(
            entries: path.entries,
            isFinished: isCoursePathEntryFinished,
            hasDoneState: coursePathEntryHasDoneState
        )
    }

    /// The name a quiz goes by when something waits on it: its topics, or
    /// its lecture for a practice quiz still carrying the ladder's placeholder.
    func courseQuizDisplayTitle(_ quizID: String) -> String {
        guard let quiz = courseQuiz(quizID) else { return "the quiz" }
        if quiz.hasTopicTitle { return quiz.title }
        return quiz.title.hasPrefix("Quiz: ") ? "the quiz on \(quiz.title.dropFirst(6))" : quiz.title
    }

    /// Whether the course's gate holds `sourceID` back: every row of it on the
    /// path is locked. Only the courses `alongside` also belongs to are asked
    /// when it is given — the player handing on from one lecture to the next
    /// is a move within their course.
    func courseLock(forSourceID sourceID: String, alongside otherSourceID: String? = nil) -> CourseLock? {
        guard let article = articlesById[sourceID] else { return nil }
        var courses = courseGroupIDs(for: article)
        if let otherSourceID, let other = articlesById[otherSourceID] {
            courses.formIntersection(courseGroupIDs(for: other))
        }
        for courseID in courses.sorted() {
            let path = coursePath(for: courseID)
            let rows = path.entries.filter { $0.sourceID == sourceID }
            guard !rows.isEmpty else { continue }
            let gate = courseGate(for: path)
            let locks = rows.compactMap { gate.state(of: $0).lockingQuizID }
            guard locks.count == rows.count, let quizID = locks.first else { continue }
            return CourseLock(courseID: courseID, quizID: quizID, quizTitle: courseQuizDisplayTitle(quizID))
        }
        return nil
    }

    // MARK: Opening a course

    /// Every course, as cards (docs/courses-design.md): the Courses list,
    /// drawn beside the Space's sidebar, in the window in scope — what "Show
    /// in Course"'s list, Open in Other Window's Courses and a course page's
    /// ‹ Courses ask for. A window holding a notebook leaves it, as for the
    /// Space.
    func openCoursesInReader(in destinationWindowState: StudioWindowState? = nil) {
        let destination = destinationWindowState ?? activeWindowState
        showSpaceTab(.courses, in: destination)
    }

    /// The Courses pane on its list, where it already is (Open Courses
    /// Beside: the pane the rail menu put beside the others), without the
    /// tab swap `openCoursesInReader` does in a Space pane.
    func openCoursesListInReader(in destinationWindowState: StudioWindowState? = nil) {
        let destination = destinationWindowState ?? activeWindowState
        destination.coursePageID = nil
        activateCenterTab(.courses, in: destination)
    }

    /// Opens one course's page. A course lives in no notebook, so it opens
    /// where the learner is: in the window's Courses pane, or — in a window
    /// holding a notebook — in that notebook's document slot
    /// (`NotebookWorkspace.route`: Courses with a page is a document), where
    /// a lecture opened from the page takes the slot in the Reader and its
    /// "Back to" brings the page back, so a course the notebook follows opens
    /// there and the learner stays where they work. It never moves the
    /// window into a notebook.
    func openCourse(_ courseID: String, in destinationWindowState: StudioWindowState? = nil) {
        let destination = destinationWindowState ?? activeWindowState
        destination.coursePageID = courseID
        activateCenterTab(.courses, in: destination)
    }

    /// Back from a course's page. In a notebook the page is a document and
    /// the course list has no place there, so the page's slot empties, as
    /// its × does. Outside one, the pane shows the list of courses in the
    /// page's place.
    func closeCoursePage(in windowState: StudioWindowState) {
        if windowState.notebook != nil {
            closeInNotebook(.courses, in: windowState)
            windowState.coursePageID = nil
            return
        }
        windowState.coursePageID = nil
    }

    /// Opens a lecture, reading or material from its course's page in the
    /// Reader beside the page, the way a chat citation keeps its chat on
    /// screen: the path stays in view while the lecture plays, Khan Academy's
    /// lesson beside its unit.
    func openCourseSource(_ sourceID: String, in windowState: StudioWindowState) async {
        showReaderPanel = true
        readerPoppedOut = false
        revealReader(beside: .courses, in: windowState)
        clearReaderSurfaces(keeping: .courses, in: windowState)
        windowState.sidebarSelectedSourceIDs = [sourceID]
        await selectArticle(sourceID, in: windowState)
    }

    /// Opens a textbook reading beside its course's page, at its first page
    /// with the opening section's heading marked (`openTextbookReading`).
    func openCourseReading(_ reading: CourseTextbookReading, in windowState: StudioWindowState) async {
        let chapterID = reading.chapter.id
        await openCourseSource(chapterID, in: windowState)
        if let pages = reading.pages {
            requestReaderPassage(reading.openingHeading, page: pages.lowerBound, for: chapterID)
        }
    }

    /// Shows a course's source in its own Library tab, scrolled to its row:
    /// the lecture video under YouTube, the paper under Papers. Nothing for
    /// course material, which has no tab. The Library opens beside what the
    /// window shows.
    func showCourseSourceInSources(_ article: StudioArticle, in windowState: StudioWindowState) {
        guard let tab = sidebarTab(listing: article) else { return }
        inWindow(windowState) {
            openCenterTabBeside(.library)
            switchTab(to: tab)
            if let group = article.parentGroup {
                sidebarStore.expandedGroups.insert(group)
            }
            windowState.sidebarSelectedSourceIDs = [article.id]
            revealSourceInSidebar(article)
        }
    }
}

extension StudioViewModel {
    /// The courses a source is on, in the Courses home's order.
    func courseIDs(containing article: StudioArticle) -> [String] {
        let memberships = courseGroupIDs(for: article)
        guard !memberships.isEmpty else { return [] }
        return allCourseGroupNames.filter(memberships.contains)
    }
}
