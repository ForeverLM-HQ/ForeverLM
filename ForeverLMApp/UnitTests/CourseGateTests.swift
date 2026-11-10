import Foundation
import Testing
@testable import ForeverLM

/// The Courses pane's path and its gate (docs/courses-design.md): every written
/// quiz holds back what comes after it until a sitting is completed. The pass
/// mark remains separate mastery feedback.
@Suite("Course gate")
@MainActor
struct CourseGateTests {

    // MARK: The pass mark

    @Test("Three in four right passes, rounded up")
    func passMark() {
        #expect(LectureQuizScore.rightNeededToPass(total: 1) == 1)
        #expect(LectureQuizScore.rightNeededToPass(total: 2) == 2)
        #expect(LectureQuizScore.rightNeededToPass(total: 3) == 3)
        #expect(LectureQuizScore.rightNeededToPass(total: 4) == 3)
        #expect(LectureQuizScore.rightNeededToPass(total: 5) == 4)
        #expect(LectureQuizScore.rightNeededToPass(total: 8) == 6)
        #expect(LectureQuizScore.rightNeededToPass(total: 10) == 8)
        #expect(LectureQuizScore.rightNeededToPass(total: 12) == 9)
        #expect(LectureQuizScore(right: 6, total: 8, takenAt: Date()).passes)
        #expect(!LectureQuizScore(right: 5, total: 8, takenAt: Date()).passes)
    }

    @Test("A quiz score gives the bounded fraction drawn in its trailing ring")
    func scoreRingFraction() {
        #expect(LectureQuizScore(right: 6, total: 8, takenAt: Date()).fractionRight == 0.75)
        #expect(!LectureQuizScore(right: 6, total: 8, takenAt: Date()).isFullyRight)
        #expect(LectureQuizScore(right: 8, total: 8, takenAt: Date()).fractionRight == 1)
        #expect(LectureQuizScore(right: 8, total: 8, takenAt: Date()).isFullyRight)
        #expect(LectureQuizScore(right: 8, total: 8, takenAt: Date()).matches(questionCount: 8))
        #expect(!LectureQuizScore(right: 3, total: 4, takenAt: Date()).matches(questionCount: 15))
        #expect(LectureQuizScore(right: 9, total: 8, takenAt: Date()).fractionRight == 1)
        #expect(LectureQuizScore(right: -1, total: 8, takenAt: Date()).fractionRight == 0)
        #expect(LectureQuizScore(right: 0, total: 0, takenAt: Date()).fractionRight == 0)
        #expect(!LectureQuizScore(right: 0, total: 0, takenAt: Date()).isFullyRight)
    }

    @Test("A worse retake keeps the first pass")
    func worseRetakeKeepsPass() {
        let first = LectureQuizScore(right: 7, total: 8, takenAt: Date(timeIntervalSince1970: 100)).recorded(after: nil)
        #expect(first.passedAt == Date(timeIntervalSince1970: 100))

        let retake = LectureQuizScore(right: 2, total: 8, takenAt: Date(timeIntervalSince1970: 200)).recorded(after: first)
        #expect(retake.label == "2 of 8 right", "the row shows the latest sitting")
        #expect(!retake.passes)
        #expect(retake.hasPassed, "but the quiz stays passed")
        #expect(retake.passedAt == Date(timeIntervalSince1970: 100))

        let failed = LectureQuizScore(right: 1, total: 8, takenAt: Date(timeIntervalSince1970: 50)).recorded(after: nil)
        #expect(!failed.hasPassed)
        #expect(failed.passedAt == nil)
    }

    @Test("A stored row keeps its pass, and a row from before passes were kept still reads")
    func preferenceRoundTrip() {
        let score = LectureQuizScore(
            right: 2, total: 4,
            takenAt: Date(timeIntervalSince1970: 300),
            passedAt: Date(timeIntervalSince1970: 100)
        )
        #expect(LectureQuizScore(preferenceValue: score.preferenceValue) == score)

        let legacy = LectureQuizScore(preferenceValue: ["right": 3, "total": 4, "takenAt": 50.0] as [String: Any])
        #expect(legacy?.passedAt == nil)
        #expect(legacy?.hasPassed == true, "a legacy row's own score still says it passed")
        let after = LectureQuizScore(right: 0, total: 4, takenAt: Date(timeIntervalSince1970: 60)).recorded(after: legacy)
        #expect(after.passedAt == Date(timeIntervalSince1970: 50))
    }

    // MARK: The gate over a course

    private let courseID = "bioenergetics"

    private func makeViewModel() -> StudioViewModel {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("CourseGateTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return StudioViewModel(storageService: StorageService(storeRoot: tmp))
    }

    private func quiz(lectureID: String) -> CourseQuiz {
        CourseQuiz(
            id: CourseQuizPlanning.practiceID(courseID: courseID, lectureID: lectureID),
            courseID: courseID,
            kind: .practice,
            title: "Quiz: \(lectureID)",
            lectureIDs: [lectureID],
            afterLectureID: lectureID,
            questions: (1...4).map { (index: Int) in
                CourseQuizQuestion(
                    id: "q\(index)", sourceID: "video-\(lectureID)", firstLine: index, lastLine: index,
                    startSeconds: nil, question: "Question \(index)?", answer: "Answer \(index).",
                    keyPoints: [], quote: nil
                )
            },
            author: .foreverlm,
            createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            updatedAt: Date(timeIntervalSinceReferenceDate: 800_000_000)
        )
    }

    /// Three lectures, each a video; the first two have a written quiz.
    private func makeCourse(in vm: StudioViewModel) -> (videos: [StudioArticle], quizzes: [CourseQuiz]) {
        let lectures = (1...3).map { CourseSession(id: "l\($0)", courseName: courseID, number: $0, title: "Lecture \($0)") }
        let videos = lectures.map { lecture in
            StudioArticle(
                url: "https://www.youtube.com/watch?v=\(lecture.id)00000000",
                title: "\(lecture.number)) Lecture \(lecture.number)",
                sourceType: .video,
                id: "video-\(lecture.id)"
            )
        }
        vm.articles = videos
        vm.courseMetadata = [courseID: CourseMetadata(title: "Mitochondrial Bioenergetics")]
        vm.courseLecturesByCourse[courseID] = lectures
        for (lecture, video) in zip(lectures, videos) {
            vm.courseLectureItemsByLectureId[lecture.id] = [
                CourseLectureItem(id: "item-\(lecture.id)", lectureId: lecture.id, sourceId: video.id, role: .video, sortIndex: 0),
            ]
        }
        let quizzes = [quiz(lectureID: "l1"), quiz(lectureID: "l2")]
        vm.courseQuizzesByCourse[courseID] = quizzes
        vm.courseQuizScores = [:]
        return (videos, quizzes)
    }

    private func states(_ vm: StudioViewModel) -> [String: CourseStepState] {
        vm.courseGate(for: vm.coursePath(for: courseID)).states
    }

    @Test("The page is a unit per lecture, its video then its quiz")
    func unitsInLectureOrder() {
        let vm = makeViewModel()
        _ = makeCourse(in: vm)
        let path = vm.coursePath(for: courseID)
        #expect(path.blocks.count == 3)
        #expect(path.entries.map(\.id) == [
            "video-item-l1", "quiz-\(CourseQuizPlanning.practiceID(courseID: courseID, lectureID: "l1"))",
            "video-item-l2", "quiz-\(CourseQuizPlanning.practiceID(courseID: courseID, lectureID: "l2"))",
            "video-item-l3",
        ])
        if case .unit(let first) = path.blocks.first {
            #expect(first.title == "Lecture 1", "the unit title drops the playlist's number")
        } else {
            Issue.record("the first block should be a lecture")
        }
    }

    @Test("Everything after a quiz not yet completed is locked; Continue starts at the top")
    func uncompletedQuizLocksWhatFollows() {
        let vm = makeViewModel()
        let (_, quizzes) = makeCourse(in: vm)
        let gate = vm.courseGate(for: vm.coursePath(for: courseID))
        #expect(gate.state(of: vm.coursePath(for: courseID).entries[0]) == .open)
        #expect(gate.states["quiz-\(quizzes[0].id)"] == .open, "the quiz that holds the rest back can be taken")
        #expect(gate.states["video-item-l2"] == .locked(quizID: quizzes[0].id))
        #expect(gate.states["quiz-\(quizzes[1].id)"] == .locked(quizID: quizzes[0].id))
        #expect(gate.states["video-item-l3"] == .locked(quizID: quizzes[0].id))
        #expect(gate.blockingQuizID == quizzes[0].id)
        #expect(gate.nextEntryID == "video-item-l1")
    }

    @Test("Completing a quiz opens the next lecture even below the pass mark")
    func completionOpensTheNextLecture() {
        let vm = makeViewModel()
        let (videos, quizzes) = makeCourse(in: vm)
        vm.sourceReviewedAt[videos[0].id] = Date()
        #expect(vm.courseGate(for: vm.coursePath(for: courseID)).nextEntryID == "quiz-\(quizzes[0].id)",
                "with the lecture watched, Continue goes to its quiz")

        // The reported case: five of eight is below the six-answer pass mark,
        // but the sitting is complete and must open the next quiz.
        vm.courseQuizScores[quizzes[0].id] = LectureQuizScore(right: 5, total: 8, takenAt: Date())
        let opened = states(vm)
        #expect(opened["quiz-\(quizzes[0].id)"] == .finished)
        #expect(opened["video-item-l2"] == .open)
        #expect(opened["quiz-\(quizzes[1].id)"] == .open)
        #expect(opened["video-item-l3"] == .locked(quizID: quizzes[1].id))
        #expect(vm.courseGate(for: vm.coursePath(for: courseID)).nextEntryID == "video-item-l2")

        vm.sourceReviewedAt[videos[1].id] = Date()
        #expect(vm.courseGate(for: vm.coursePath(for: courseID)).nextEntryID == "quiz-\(quizzes[1].id)",
                "when the next lecture is already watched, its quiz is the next unlocked row")
    }

    @Test("What the learner already finished stays open behind an uncompleted quiz")
    func finishedWorkStaysOpen() {
        let vm = makeViewModel()
        let (videos, _) = makeCourse(in: vm)
        vm.sourceReviewedAt[videos[2].id] = Date()
        #expect(states(vm)["video-item-l3"] == .finished)
    }

    @Test("The player is turned back from a locked lecture, and let through once the quiz is completed")
    func playerHandoffLock() {
        let vm = makeViewModel()
        let (videos, quizzes) = makeCourse(in: vm)
        let lock = vm.courseLock(forSourceID: videos[1].id, alongside: videos[0].id)
        #expect(lock?.quizID == quizzes[0].id)
        #expect(lock?.courseID == courseID)
        #expect(vm.courseLock(forSourceID: videos[0].id, alongside: videos[1].id) == nil)

        vm.courseQuizScores[quizzes[0].id] = LectureQuizScore(right: 0, total: 4, takenAt: Date())
        #expect(vm.courseLock(forSourceID: videos[1].id, alongside: videos[0].id) == nil)
    }

    @Test("A lesson sheet with no done state is not waited on, and gets no mark")
    func untrackedMaterialIsPassedOver() {
        let vm = makeViewModel()
        let (videos, quizzes) = makeCourse(in: vm)
        // Lecture 1's slides: a course's own PDF, which can be reviewed but
        // never watched or marked read.
        let slides = StudioArticle(
            url: "foreverlm://course/\(courseID)/lesson/1",
            title: "Lecture 1 slides",
            sourceType: .course,
            id: "slides-l1"
        )
        vm.articles = videos + [slides]
        vm.courseLectureItemsByLectureId["l1"]?.append(
            CourseLectureItem(id: "item-slides-l1", lectureId: "l1", sourceId: slides.id, role: .slides, sortIndex: 1)
        )
        vm.sourceReviewedAt[videos[0].id] = Date()

        let path = vm.coursePath(for: courseID)
        let gate = vm.courseGate(for: path)
        let slidesRow = path.entries.first { $0.id == "material-item-slides-l1" }
        #expect(slidesRow != nil)
        #expect(gate.states["material-item-slides-l1"] == .open)
        #expect(slidesRow.map(gate.tracksCompletion) == false, "nothing could ever fill its ring")
        #expect(gate.nextEntryID == "quiz-\(quizzes[0].id)", "Continue goes past the slides to the quiz")

        // Reviewed, the slides are done like anything else.
        vm.sourceReviewedAt[slides.id] = Date()
        let reviewed = vm.courseGate(for: vm.coursePath(for: courseID))
        #expect(reviewed.states["material-item-slides-l1"] == .finished)
        #expect(slidesRow.map(reviewed.tracksCompletion) == true)

        // Behind a quiz not yet completed, they are held back like the rest.
        vm.courseLectureItemsByLectureId["l2"]?.append(
            CourseLectureItem(id: "item-slides-l2", lectureId: "l2", sourceId: slides.id, role: .slides, sortIndex: 1)
        )
        vm.sourceReviewedAt[slides.id] = nil
        #expect(states(vm)["material-item-slides-l2"] == .locked(quizID: quizzes[0].id))
    }

    @Test("A completed retake does not lock the lectures after it")
    func completedRetakeDoesNotRelock() {
        let vm = makeViewModel()
        let (_, quizzes) = makeCourse(in: vm)
        let key = LectureQuizScore.preferenceKey(courseQuizID: quizzes[0].id)
        // Through PreferenceStore, so the synced row it wrote is deleted too.
        defer { PreferenceStore.remove(forKey: key) }

        vm.recordCourseQuizScore(LectureQuizScore(right: 4, total: 4, takenAt: Date()), quizID: quizzes[0].id)
        vm.recordCourseQuizScore(LectureQuizScore(right: 0, total: 4, takenAt: Date()), quizID: quizzes[0].id)

        #expect(vm.courseQuizScores[quizzes[0].id]?.label == "0 of 4 right")
        #expect(vm.isCourseQuizCompleted(quizzes[0].id))
        #expect(states(vm)["video-item-l2"] != .locked(quizID: quizzes[0].id))
    }
}
