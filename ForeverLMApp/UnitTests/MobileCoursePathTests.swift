import Foundation
import Testing
@testable import ForeverLM

/// The phone's course page: the Mac's path order and gate over the synced
/// outline and quizzes (docs/courses-design.md, "Cross-client parity").
@Suite("Mobile course path and gate")
struct MobileCoursePathTests {

    private let courseID = "bioenergetics"

    private func source(
        _ id: String,
        type: String,
        title: String? = nil,
        url: String? = nil,
        parentGroup: String? = nil,
        readAt: Date? = nil,
        locator: String? = nil
    ) -> MobileCloudSource {
        MobileCloudSource(
            id: id,
            title: title ?? id,
            subtitle: nil,
            sourceType: type,
            dateAdded: Date(timeIntervalSinceReferenceDate: 0),
            hasAudio: false,
            isArchived: false,
            parentGroup: parentGroup,
            url: url,
            readAt: readAt,
            readingPositionLocator: locator
        )
    }

    private func question(_ id: String, sourceID: String = "vid-1", quote: String? = nil) -> CourseQuizQuestion {
        CourseQuizQuestion(
            id: id,
            sourceID: sourceID,
            firstLine: 1,
            lastLine: 2,
            startSeconds: nil,
            question: "Why \(id)?",
            answer: "Because.",
            keyPoints: [],
            quote: quote
        )
    }

    private func quiz(
        _ id: String,
        kind: CourseQuiz.Kind,
        title: String,
        lectureIDs: [String],
        after: String?,
        questions: Int = 4
    ) -> CourseQuiz {
        CourseQuiz(
            id: id,
            courseID: courseID,
            kind: kind,
            title: title,
            lectureIDs: lectureIDs,
            afterLectureID: after,
            questions: (0..<questions).map { question("q\($0)") },
            author: .foreverlm,
            createdAt: Date(timeIntervalSinceReferenceDate: 0),
            updatedAt: Date(timeIntervalSinceReferenceDate: 0)
        )
    }

    private var practiceID: String { CourseQuizPlanning.practiceID(courseID: courseID, lectureID: "l1") }

    /// Two lectures: the first with its video, an assigned paper, a paper
    /// the video only cites, and a course PDF; its practice quiz; the
    /// second's video; and a checkpoint over both after it.
    private func course(quizzes: [CourseQuiz]? = nil) -> MobileCloudCourse {
        MobileCloudCourse(
            id: courseID,
            title: "Mitochondrial Bioenergetics",
            institution: nil,
            isHidden: false,
            lectures: [
                MobileCourseLecture(id: "l2", number: 2, title: "2) Ion Transport"),
                MobileCourseLecture(id: "l1", number: 1, title: "1) Isolated Mitochondria"),
            ],
            lectureItems: [
                MobileCourseLectureItem(id: "i1", lectureID: "l1", sourceID: "vid-1", role: "video", sortIndex: 0),
                MobileCourseLectureItem(id: "i2", lectureID: "l1", sourceID: "paper-assigned", role: "reading", sortIndex: 1),
                MobileCourseLectureItem(id: "i3", lectureID: "l1", sourceID: "paper-cited", role: "reference", sortIndex: 2),
                MobileCourseLectureItem(id: "i4", lectureID: "l1", sourceID: "handout", role: "notes", sortIndex: 3),
                MobileCourseLectureItem(id: "i5", lectureID: "l2", sourceID: "vid-2", role: "video", sortIndex: 0),
            ],
            quizzes: quizzes ?? [
                quiz(practiceID, kind: .practice, title: "Quiz: Isolated Mitochondria", lectureIDs: ["l1"], after: "l1"),
                quiz("cp", kind: .checkpoint, title: "Quiz 2", lectureIDs: ["l1", "l2"], after: "l2"),
                quiz("empty", kind: .checkpoint, title: "Quiz 3", lectureIDs: ["l2"], after: "l2", questions: 0),
            ]
        )
    }

    private func sources(watchedFirst: Bool = false, paperRead: Bool = false) -> [MobileCloudSource] {
        let watched = VideoWatchProgress(positionSeconds: 1800, watchedSeconds: 1800, durationSeconds: 1800).encoded
        return [
            source("vid-1", type: "video", locator: watchedFirst ? watched : nil),
            source("paper-assigned", type: "paper", readAt: paperRead ? Date() : nil),
            source("paper-cited", type: "paper"),
            source("handout", type: "course"),
            source("vid-2", type: "video"),
            source("extra", type: "course", parentGroup: "bioenergetics"),
        ]
    }

    @Test("The path runs in the Mac's order, without cited-only papers or empty quizzes")
    func pathOrder() {
        let path = MobileCoursePath.build(course: course(), sources: sources())
        #expect(path.rows.map(\.id) == [
            "video-i1", "material-i2", "material-i4", "quiz-\(practiceID)",
            "video-i5",
            "quiz-cp",
        ])
        guard case .unit(let first) = path.blocks.first else {
            Issue.record("first block is not a unit")
            return
        }
        #expect(first.title == "Isolated Mitochondria")
        #expect(first.rows.first?.title == "1) Isolated Mitochondria")
        // The practice quiz still carries the ladder's placeholder name, so
        // its row says Quiz and names the lecture beneath.
        #expect(first.rows.last?.title == "Quiz")
        #expect(first.rows.last?.quizSubtitle == "1) Isolated Mitochondria")
        #expect(path.blocks.last.map { if case .milestone = $0 { return true } else { return false } } == true)
        #expect(path.quizRows.last?.quizSubtitle == "Lectures 1–2")
        #expect(path.furtherMaterial.map(\.id) == ["extra"])
    }

    @Test("An uncompleted quiz locks what follows it; Continue opens the first unfinished row")
    func gateLocksAfterUncompletedQuiz() {
        let path = MobileCoursePath.build(course: course(), sources: sources())
        let progress = MobileCourseProgress(scores: [:], reviewedSourceIDs: [])
        let gate = progress.gate(for: path)
        #expect(gate.nextEntryID == "video-i1")
        #expect(gate.blockingQuizID == practiceID)
        #expect(gate.states["quiz-\(practiceID)"] == .open)
        #expect(gate.states["video-i5"] == .locked(quizID: practiceID))
        #expect(gate.states["quiz-cp"] == .locked(quizID: practiceID))
        // A course handout can only be reviewed: no ring, and Continue does
        // not wait on it.
        #expect(gate.untrackedEntryIDs == ["material-i4"])
    }

    @Test("Watched, read and completed rows are done, and completion opens the next lecture")
    func completionOpensWhatFollows() {
        let path = MobileCoursePath.build(course: course(), sources: sources(watchedFirst: true, paperRead: true))
        let completed = LectureQuizScore(right: 1, total: 4, takenAt: Date(timeIntervalSinceReferenceDate: 100))
        let progress = MobileCourseProgress(
            scores: [LectureQuizScore.preferenceKey(courseQuizID: practiceID): completed],
            reviewedSourceIDs: ["handout"]
        )
        let gate = progress.gate(for: path)
        #expect(gate.states["video-i1"] == .finished)
        #expect(gate.states["material-i2"] == .finished)
        #expect(gate.states["material-i4"] == .finished)
        #expect(gate.states["quiz-\(practiceID)"] == .finished)
        #expect(gate.states["video-i5"] == .open)
        #expect(gate.nextEntryID == "video-i5")
        #expect(gate.blockingQuizID == "cp")
    }

    @Test("A quiz row says whether it passed, how many it got right, or how many questions it has")
    func quizDetail() {
        let path = MobileCoursePath.build(course: course(), sources: sources())
        let practice = path.quizRows[0]
        let key = LectureQuizScore.preferenceKey(courseQuizID: practiceID)
        let date = Date(timeIntervalSinceReferenceDate: 0)
        #expect(MobileCourseProgress(scores: [:], reviewedSourceIDs: []).quizDetail(for: practice) == "4 questions")
        #expect(MobileCourseProgress(
            scores: [key: LectureQuizScore(right: 3, total: 4, takenAt: date)], reviewedSourceIDs: []
        ).quizDetail(for: practice) == "Passed · 3 of 4 right")
        #expect(MobileCourseProgress(
            scores: [key: LectureQuizScore(right: 1, total: 4, takenAt: date)], reviewedSourceIDs: []
        ).quizDetail(for: practice) == "1 of 4 right")
        #expect(MobileCourseProgress(
            scores: [key: LectureQuizScore(right: 1, total: 4, takenAt: date, passedAt: date)], reviewedSourceIDs: []
        ).quizDetail(for: practice) == "Passed earlier · 1 of 4 right")
        #expect(MobileCourseProgress(
            scores: [key: LectureQuizScore(right: 1, total: 3, takenAt: date)], reviewedSourceIDs: []
        ).quizDetail(for: practice) == "4 questions")
        #expect(MobileCourseProgress(scores: [:], reviewedSourceIDs: []).quizDetail(for: path.quizRows[1])
            == "Lectures 1–2 · 4 questions")
    }

    @Test("A quiz whose lectures are gone ends the path")
    func orphanQuizEndsPath() {
        let orphan = quiz("orphan", kind: .test, title: "Course Test", lectureIDs: ["gone"], after: "gone")
        let path = MobileCoursePath.build(course: course(quizzes: [orphan]), sources: sources())
        #expect(path.rows.last?.id == "quiz-orphan")
        #expect(path.rows.last?.quizSubtitle == "Mitochondrial Bioenergetics")
    }

    @Test("A lecture title loses the number its section already shows")
    func strippedOrdinal() {
        #expect(MobileCoursePath.strippedLeadingOrdinal("5) Isolated Mitochondria") == "Isolated Mitochondria")
        #expect(MobileCoursePath.strippedLeadingOrdinal("3a) Part Two") == "Part Two")
        #expect(MobileCoursePath.strippedLeadingOrdinal("Lecture 3: Proton Leak") == "Proton Leak")
        #expect(MobileCoursePath.strippedLeadingOrdinal("Overview") == "Overview")
        #expect(MobileCoursePath.strippedLeadingOrdinal("10x Genomics") == "10x Genomics")
    }

    @Test("The grader gets the passage around the question's quote")
    func graderStretch() {
        let filler = String(repeating: "word ", count: 600)
        let text = "\(filler)The   inner membrane\nholds the cristae. \(filler)"
        let found = MobileCourseQuizStretch.text(
            for: question("q", quote: "inner membrane holds the cristae"),
            in: text
        )
        #expect(found.contains("The inner membrane holds the cristae."))
        #expect(found.count < text.count)
        #expect(!found.hasPrefix(" ") && !found.hasSuffix(" "))

        let missing = MobileCourseQuizStretch.text(for: question("q", quote: "not in the lecture"), in: text)
        #expect(missing == "not in the lecture")
        let noQuote = MobileCourseQuizStretch.text(for: question("q"), in: text)
        #expect(noQuote.hasPrefix("(Not available on this device"))
    }

    // MARK: - Home's Courses

    @Test("A course's card line counts its lecture videos as the Mac's Courses tab does, every item when it has none, in the Mac's words")
    func cardProgressIsTheMacs() {
        let path = MobileCoursePath.build(course: course(), sources: sources(watchedFirst: true, paperRead: true))
        let phone = MobileCourseCardProgress(path: path, reviewedSourceIDs: [])
        // The Mac's own count over the same items: the two lecture videos, the first watched.
        let mac = CourseProgress(items: [
            .init(isLectureVideo: true, isFinished: true, isStarted: true),
            .init(isLectureVideo: false, isFinished: true, isStarted: true),
            .init(isLectureVideo: false, isFinished: false, isStarted: false),
            .init(isLectureVideo: true, isFinished: false, isStarted: false),
        ])
        #expect(phone.summary == mac.summary)
        #expect(phone.summary == "1 of 2 lectures finished")
        #expect(phone.fractionFinished == mac.fractionFinished)

        let reviewed = MobileCourseCardProgress(path: path, reviewedSourceIDs: ["vid-2"])
        #expect(reviewed.summary == "All 2 lectures finished", "a reviewed lecture is finished")
        #expect(reviewed.isComplete)

        var readingsOnly = course(quizzes: [])
        readingsOnly.lectureItems = readingsOnly.lectureItems.filter { $0.role != "video" }
        let items = MobileCourseCardProgress(path: MobileCoursePath.build(course: readingsOnly, sources: sources(paperRead: true)), reviewedSourceIDs: [])
        #expect(items.summary == "1 of 3 items finished", "no video: every item filed under a lecture counts, a paper no video cites among them")
    }

    @Test("Home's Courses lists every course not hidden, by title, each with the notebooks that follow it")
    func homeCourses() {
        let hidden = MobileCloudCourse(id: "hidden", title: "A hidden course", institution: nil, isHidden: true)
        let other = MobileCloudCourse(id: "ageing", title: "Ageing Biology", institution: "Buck", isHidden: false)
        let following = MobileCloudNotebook(id: "nb1", title: "🧬 Mito", instructions: nil, sourceIDs: [], linkedCourseIDs: [courseID],
                                            isArchived: false, updatedAt: Date(timeIntervalSinceReferenceDate: 0))
        let unrelated = MobileCloudNotebook(id: "nb2", title: "Sleep", instructions: nil, sourceIDs: [], isArchived: false,
                                            updatedAt: Date(timeIntervalSinceReferenceDate: 0))
        let rows = MobileCoursesHome.rows(courses: [course(), hidden, other], sources: sources(), reviewedSourceIDs: [],
                                          notebooks: [unrelated, following])
        #expect(rows.map(\.id) == ["ageing", courseID], "hidden courses are left out; the rest by title")
        #expect(rows.first?.notebooksLine == nil, "a course no notebook follows still shows: it lives in no notebook")
        #expect(rows.last?.notebooks.map(\.id) == ["nb1"])
        #expect(rows.last?.notebooksLine == "Linked to Mito")
        #expect(rows.last?.progress.summary == "0 of 2 lectures finished")
    }
}
