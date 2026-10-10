import Foundation
import Testing
@testable import ForeverLM

/// A course's progress and gate, computed per member from the course's records and the member's
/// ReadingStates and Sittings, never stored (docs/cloudkit-schema-design.md §8d, WP9; `CourseProgressFold`).
@Suite("Course gate derivation")
struct CourseGateDerivationTests {
    typealias Fold = CourseProgressFold

    /// Two lessons: a video and a reading of pages 3–9 (PDF pages 2–8) in the first, followed by its
    /// practice quiz; a video in the second; the course test at the end.
    private static let lessons = [Fold.Lesson(id: "lec-2", orderKey: "a1"), Fold.Lesson(id: "lec-1", orderKey: "a0")]
    private static let items = [
        Fold.Item(id: "e-reading", lessonID: "lec-1", orderKey: "a1", sourceID: "src-chapter", span: .pages(first: 2, last: 8)),
        Fold.Item(id: "e-video", lessonID: "lec-1", orderKey: "a0", sourceID: "src-video"),
        Fold.Item(id: "e-video-2", lessonID: "lec-2", orderKey: "a0", sourceID: "src-video-2"),
    ]
    private static let quizzes = [
        Fold.Quiz(id: "cq-test", lessonID: nil, kind: .test, title: "Course test", revision: 1),
        Fold.Quiz(id: "cq-1", lessonID: "lec-1", kind: .practice, title: "Motifs", revision: 2),
    ]

    private static func sitting(_ quiz: String, right: Int, of: Int, at seconds: TimeInterval, revision: Int? = 2, ended: Bool = true) -> Fold.Sitting {
        Fold.Sitting(quizID: quiz, quizRevision: revision, right: right, of: of, endedAt: ended ? Date(timeIntervalSince1970: seconds) : nil)
    }

    @Test("The path is the lessons by key, each one's items by key, then the quizzes that follow it; a quiz with no lesson ends it")
    func pathOrder() {
        let path = Fold.path(lessons: Self.lessons, items: Self.items, quizzes: Self.quizzes)
        #expect(path.map(\.id) == ["e-video", "e-reading", "cq-1", "e-video-2", "cq-test"])
        #expect(path.compactMap(\.gatingQuizID) == ["cq-1", "cq-test"])
        #expect(Fold.path(lessons: Self.lessons, items: Self.items, quizzes: Self.quizzes, policy: .init(gateQuizzes: false)).compactMap(\.gatingQuizID).isEmpty)
    }

    @Test("An item is done when marked complete, read 90% into its span, or watched 90% of its span or the video")
    func itemDone() {
        let video = Self.items[1], reading = Self.items[0]
        #expect(Fold.isDone(video, reading: nil) == false)
        #expect(Fold.isDone(video, reading: .init(completed: true)))
        #expect(Fold.isDone(video, reading: .init(watchedSeconds: 901, durationSeconds: 1_000)))
        #expect(Fold.isDone(video, reading: .init(watchedSeconds: 899, durationSeconds: 1_000)) == false)
        #expect(Fold.isDone(video, reading: .init(furthest: 0.95)))
        // Pages 2–8 of a 100-page chapter: done once the reader is 90% into the span, past page 8.3.
        #expect(Fold.isDone(reading, reading: .init(furthest: 0.08, pageCount: 100)) == false)
        #expect(Fold.isDone(reading, reading: .init(furthest: 0.084, pageCount: 100)))
        #expect(Fold.isDone(reading, reading: .init(furthest: 0.95)) == false, "with no page count the span cannot be placed")
        let clip = Fold.Item(id: "e-clip", lessonID: "lec-1", orderKey: "a2", sourceID: "src-video", span: .seconds(from: 600, to: 700))
        #expect(Fold.isDone(clip, reading: .init(watchedSeconds: 689)) == false)
        #expect(Fold.isDone(clip, reading: .init(watchedSeconds: 691)))
    }

    @Test("The first quiz without a completed sitting locks what is unfinished after it; finished work stays open")
    func gateLocks() {
        let readings: [String: Fold.Reading] = ["src-video": .init(completed: true), "src-video-2": .init(completed: true)]
        let progress = Fold.progress(lessons: Self.lessons, items: Self.items, quizzes: Self.quizzes, readings: readings, sittings: [])
        #expect(progress.gate.blockingQuizID == "cq-1")
        #expect(progress.gate.states["e-video"] == .finished)
        #expect(progress.gate.states["e-reading"] == .open)
        #expect(progress.gate.states["cq-1"] == .open)
        #expect(progress.gate.states["e-video-2"] == .finished, "finished work after the quiz stays open")
        #expect(progress.gate.states["cq-test"] == .locked(quizID: "cq-1"))
        #expect(progress.gate.nextEntryID == "e-reading")
        #expect(progress.done == 2 && progress.total == 5)
    }

    @Test("A completed sitting opens the rest whatever it scored; a pass is kept through worse retakes; an earlier revision's is flagged")
    func sittingsComplete() {
        let failed = Fold.progress(lessons: Self.lessons, items: Self.items, quizzes: Self.quizzes, readings: [:],
                                   sittings: [Self.sitting("cq-1", right: 1, of: 4, at: 10)])
        #expect(failed.finished.contains("cq-1"))
        #expect(failed.quizzes["cq-1"] == .init(right: 1, of: 4, passed: false, previousVersion: false))
        #expect(failed.gate.states["e-video-2"] == .open, "a completed sitting is what opens the rest")
        #expect(failed.gate.blockingQuizID == "cq-test")

        let retaken = Fold.progress(lessons: Self.lessons, items: Self.items, quizzes: Self.quizzes, readings: [:], sittings: [
            Self.sitting("cq-1", right: 3, of: 4, at: 10),
            Self.sitting("cq-1", right: 1, of: 4, at: 20),
            Self.sitting("cq-1", right: 4, of: 4, at: 30, ended: false),
        ])
        #expect(retaken.quizzes["cq-1"] == .init(right: 1, of: 4, passed: true, previousVersion: false),
                "the latest completed sitting shows; the earlier pass stands; a sitting under way is not counted")

        let earlier = Fold.progress(lessons: Self.lessons, items: Self.items, quizzes: Self.quizzes, readings: [:],
                                    sittings: [Self.sitting("cq-1", right: 2, of: 3, at: 10, revision: 1)])
        #expect(earlier.quizzes["cq-1"]?.previousVersion == true)
        #expect(earlier.quizzes["cq-1"]?.passed == false, "3 questions need all three")
    }

    @Test("The course's policy sets the pass mark, and a course that does not gate locks nothing")
    func policy() {
        #expect(Fold.Policy().rightNeeded(total: 4) == 3)
        #expect(Fold.Policy().rightNeeded(total: 3) == 3)
        #expect(Fold.Policy(pass: (right: 1, of: 2)).rightNeeded(total: 5) == 3)
        let lenient = Fold.Policy(pass: (right: 1, of: 2))
        #expect(Fold.standing(of: Self.quizzes[1], sittings: [Self.sitting("cq-1", right: 2, of: 4, at: 1)], policy: lenient)?.passed == true)
        let open = Fold.progress(lessons: Self.lessons, items: Self.items, quizzes: Self.quizzes, policy: .init(gateQuizzes: false), readings: [:], sittings: [])
        #expect(open.gate.blockingQuizID == nil)
        #expect(!open.gate.states.values.contains { $0.lockingQuizID != nil })
    }

    @Test("An item that is not required is not counted and Continue passes over it")
    func notRequired() {
        var items = Self.items
        items[1].required = false
        let progress = Fold.progress(lessons: Self.lessons, items: items, quizzes: [], readings: [:], sittings: [])
        #expect(progress.total == 2)
        #expect(progress.gate.nextEntryID == "e-reading")
    }
}
