import Foundation
import Testing
@testable import ForeverLM

/// Copies into a space (docs/cloudkit-schema-design.md §4.3, §5.3 "copy", §5.5, §9.3, §9.4, D21, D41,
/// WP15): a copy into a space leaves the original exactly as it was; the copy starts active, carries no
/// member-local value and names the original's satellites verbatim; a course is copied, never moved,
/// with every source its lessons name, and its lesson Entries name the sources' wire ids.
@Suite("Space copies", .serialized)
struct SpaceCopyTests {
    typealias S = SpaceTestFixture
    typealias F = NotebookSyncFixture
    typealias C = CourseSyncFixture

    @Test("A source copied into someone else's space: the original untouched, the copy active, with no member-local field and the same FileRefs")
    func sourceCopy() throws {
        let (root, store) = try F.makeStore("copy-source")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        let zone = try S.holdSpace(store, spaceID: "s1", owner: "_alice")
        var article = SourceSyncFixture.article("https://example.org/paper", title: "A paper", state: .ready)
        article.content = "Text"
        article.discoveryOrigin = .safari
        try SourceSyncFixture.save(store, article)
        try store.execute("UPDATE sources SET status = 'archived' WHERE id = ?", [.text(article.id)])
        let file = #"{"owner":"\#(article.id)","role":"pdf","hash":"abc","size":3}"#
        try store.execute("INSERT INTO source_files (source_id, role, file_ref) VALUES (?, 'pdf', ?)", [.text(article.id), .text(file)])
        let before = try F.text(store, "SELECT team_id || '|' || status FROM sources WHERE id = ?", [.text(article.id)])

        let copyID = try store.copySourceIntoSpace(article.id, spaceID: "s1")
        #expect(copyID == SpaceLocalID.localID(spaceID: "s1", type: .source, wireID: article.id))
        #expect(try store.copySourceIntoSpace(article.id, spaceID: "s1") == copyID, "the space holds one copy")
        #expect(try F.text(store, "SELECT team_id || '|' || status FROM sources WHERE id = ?", [.text(article.id)]) == before, "the original untouched")
        #expect(try F.text(store, "SELECT team_id || '|' || status || '|' || wire_id FROM sources WHERE id = ?", [.text(copyID)]) == "s1|active|\(article.id)")
        #expect(try store.loadSourceForSync(copyID)?.discoveryOrigin == nil, "who found it, and how, stays the learner's")
        #expect(try F.text(store, "SELECT file_ref FROM source_files WHERE source_id = ? AND role = 'pdf'", [.text(copyID)]) == file, "verbatim (D41)")

        let change = try #require(try OutboxFeeder(connection: store, registry: F.registry).pendingChanges(now: Date().addingTimeInterval(60))
            .first { $0.zoneKey == zone && $0.wireID == article.id })
        let fields = try #require(F.savedFields(change))
        #expect(SpaceWriteGuard.refusals(writing: "Source", fields: fields, by: SpaceWriteGuard.Writer(user: "_bob", permission: .readWrite, isOwner: false)).isEmpty)
        #expect(fields["status"] == .string("active"))
    }

    @Test("A course copied into a team's space carries its lessons, quizzes and every source they name; the original stays")
    func courseCopy() throws {
        let (root, store) = try F.makeStore("copy-course")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try S.addTeam(store, "s1")
        let zone = try S.holdSpace(store, spaceID: "s1")
        try C.addSampleCourse(store)
        try F.sendAll(store)

        let copy = try store.copyCourseIntoSpace("crs-1", spaceID: "s1") { _ in nil }
        #expect(copy.id != "crs-1")
        #expect(try F.text(store, "SELECT team_id FROM courses WHERE id = 'crs-1'") == nil, "the original course stays as it was")
        #expect(try F.text(store, "SELECT team_id FROM courses WHERE id = ?", [.text(copy.id)]) == "s1")
        #expect(try F.count(store, "SELECT COUNT(*) FROM course_lectures WHERE course_id = ?", [.text(copy.id)]) == 2)
        #expect(try F.count(store, "SELECT COUNT(*) FROM course_quizzes WHERE course_id = ?", [.text(copy.id)]) == 1)

        let pending = try OutboxFeeder(connection: store, registry: F.registry).pendingChanges(now: Date().addingTimeInterval(60))
        let inSpace = pending.filter { $0.zoneKey == zone }
        #expect(inSpace.contains { $0.recordType == .course && $0.wireID == copy.id })
        #expect(inSpace.filter { $0.recordType == .lesson }.count == 2)
        #expect(inSpace.filter { $0.recordType == .quiz }.count == 1)
        for source in ["src-video", "src-chapter", "src-video-2"] {
            #expect(inSpace.contains { $0.recordType == .source && $0.wireID == source }, "the space's copy of \(source) goes under the source's id")
        }
        let lessonEntries = inSpace.filter { $0.recordType == .entry }
        #expect(lessonEntries.count == 4)
        #expect(lessonEntries.allSatisfy { change in ["src-video", "src-chapter", "src-video-2"].contains { change.wireID.contains(":source:\($0)") } },
                "named by the sources' wire ids: \(lessonEntries.map(\.wireID))")
        #expect(pending.filter { $0.zoneKey == F.libraryZoneKey && $0.recordType == .course }.isEmpty, "nothing of the original moves")
    }
}
