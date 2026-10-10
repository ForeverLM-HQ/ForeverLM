import Foundation
import Testing
@testable import ForeverLM

/// Courses under generation 2 (docs/cloudkit-schema-design.md D25, §3.5.9, §3.5.10, §8d, §14.2 WP19b): a
/// course's lessons in path order, numbered, each with its sources in their order, read from the index
/// as the Courses screens' `MobileCloudCourse`; a notebook links the courses it follows (a course lives in
/// no notebook, revision 9).
@Suite("iPhone course read models", .serialized)
struct MobileCourseModelTests {
    typealias F = MobileReadModelFixture

    static func fixture() async throws -> MobileReplica {
        let replica = try await F.replica()
        let L = F.library, C = F.catalog
        func course(_ id: String, _ title: String, created: Int64, _ extra: [String: SyncJSON] = [:]) throws -> SyncEnvelope {
            var fields: [String: SyncJSON] = ["title": .string(title), "status": .string("active"), "createdAt": SyncJSON(created),
                                              "policy": .object(["gateQuizzes": .bool(false), "pass": .null])]
            fields.merge(extra) { $1 }
            return try MobileSyncFixture.envelope(.course, id, fields)
        }
        func lesson(_ id: String, course: String, order: String, title: String?, label: String? = nil) throws -> SyncEnvelope {
            var fields: [String: SyncJSON] = ["courseID": .string(course), "orderKey": .string(order), "kind": .string("lecture"), "createdAt": SyncJSON(1)]
            if let title { fields["title"] = .string(title) }
            if let label { fields["label"] = .string(label) }
            return try MobileSyncFixture.envelope(.lesson, id, fields)
        }
        try await MobileSyncFixture.apply([
            (L, try F.notebook("nb-a", "Alpha", edited: 10)),
            (L, try course("crs1", "Cells 101", created: 2, ["provider": .string("MIT OCW")])),
            (L, try F.entry("nb-a", "course", "crs1", order: "a")),
            (L, try course("crs-old", "Retired", created: 1, ["status": .string("archived")])),
            (L, try lesson("les2", course: "crs1", order: "b", title: "Membranes")),
            (L, try lesson("les1", course: "crs1", order: "a", title: "Organelles")),
            (L, try lesson("les3", course: "crs1", order: "c", title: nil, label: "Lecture 3")),
            (L, try F.entry("les1", "source", "s-read", order: "b", containerKind: "lesson", ["role": .string("reading")])),
            (L, try F.entry("les1", "source", "s-video", order: "a", containerKind: "lesson", ["role": .string("video")])),
            (L, try F.entry("les1", "source", "s-gone", order: "c", containerKind: "lesson", ["state": .string("removed")])),
            (L, try F.entry("les2", "source", "s-notes", order: "a", containerKind: "lesson")),
            (L, try F.entry("les2", "quiz", "qz1", order: "b", containerKind: "lesson", ["role": .string("quiz")])),
            (C, try F.source("s-read", "Reading", added: 1)),
            (C, try F.source("s-video", "Lecture video", added: 2, type: "video")),
            (C, try F.source("s-notes", "Notes", added: 3)),
        ], to: replica)
        return replica
    }

    @Test("A course's lessons come in path order, numbered, each with its active sources in order and their roles")
    func lessons() async throws {
        let replica = try await Self.fixture()
        let snapshot = try await MobileReadModels.snapshot(MobileProjection(replica: replica))
        let course = try #require(snapshot.collections.coursesByID["crs1"])
        #expect(course.title == "Cells 101" && course.institution == "MIT OCW" && !course.isHidden)
        #expect(course.lectures == [
            MobileCourseLecture(id: "les1", number: 1, title: "Organelles"),
            MobileCourseLecture(id: "les2", number: 2, title: "Membranes"),
            MobileCourseLecture(id: "les3", number: 3, title: "Lecture 3"),
        ])
        #expect(course.lectureItems.map(\.sourceID) == ["s-video", "s-read", "s-notes"], "removed items and quizzes are not sources")
        #expect(course.lectureItems.map(\.role) == ["video", "reading", "reading"])
        #expect(course.lectureItems.map(\.sortIndex) == [0, 1, 0])
        #expect(course.lectureItems.map(\.lectureID) == ["les1", "les1", "les2"])
        #expect(course.quizzes.isEmpty, "quiz questions are satellites, fetched on demand")
        #expect(snapshot.collections.coursesByID["crs-old"]?.isHidden == true, "an archived course is hidden, as a hidden one is on generation 1")
    }

    @Test("A notebook links the courses it follows")
    func followedCourses() async throws {
        let replica = try await Self.fixture()
        let snapshot = try await MobileReadModels.snapshot(MobileProjection(replica: replica))
        #expect(snapshot.notebooks.first { $0.id == "nb-a" }?.linkedCourseIDs == ["crs1"])
        #expect(try await MobileProjection(replica: replica).lessons(ofCourse: "crs1").map(\.id) == ["les1", "les2", "les3"])
    }

    @Test("A course page loads its quizzes again once the catalog holds the course, and when its lessons change")
    func quizzesLoadWhenTheCourseArrives() async throws {
        let before = MobileCourseQuizzes.loadKey(courseID: "crs1", course: nil)
        let snapshot = try await MobileReadModels.snapshot(MobileProjection(replica: try await Self.fixture()))
        let course = try #require(snapshot.collections.coursesByID["crs1"])
        let arrived = MobileCourseQuizzes.loadKey(courseID: "crs1", course: course)
        #expect(arrived == ["crs1", "les1", "les2", "les3"])
        #expect(arrived != before, "the task that read nothing is replaced, or the page lists no quizzes until it is reopened")
        var more = course
        more.lectures.append(MobileCourseLecture(id: "les4", number: 4, title: nil))
        #expect(MobileCourseQuizzes.loadKey(courseID: "crs1", course: more) != arrived)
    }
}
