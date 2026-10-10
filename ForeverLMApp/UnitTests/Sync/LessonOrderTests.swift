import Foundation
import Testing
@testable import ForeverLM

/// A course's lesson order and a lesson's item order under generation 2 (docs/cloudkit-schema-design.md
/// §3.5.8, §3.5.10, §8d, WP9): fractional keys that move only the rows a reorder moved, an inbound order
/// that rewrites `lecture_number` and `sort_index`, and two page ranges of one source in one lesson as two
/// Entries (`#2`) whose names never move.
@Suite("Lesson order")
struct LessonOrderTests {
    typealias F = NotebookSyncFixture
    typealias C = CourseSyncFixture

    private static func lessonOrder(_ store: KnowledgeStore, course: String = "crs-1") throws -> [String] {
        var ids: [String] = []
        try store.query("SELECT id FROM course_lectures WHERE course_id = ? ORDER BY order_key", [.text(course)]) { ids.append($0.text(0) ?? "") }
        return ids
    }

    private static func numbers(_ store: KnowledgeStore, course: String = "crs-1") throws -> String? {
        try F.text(store, "SELECT group_concat(id || '=' || lecture_number, ',') FROM (SELECT * FROM course_lectures WHERE course_id = ? ORDER BY id)", [.text(course)])
    }

    @Test("Lessons are keyed in lecture order, and moving one lecture sends that Lesson's key alone")
    func reorderSendsOneKey() throws {
        let (root, store) = try F.makeStore("lesson-reorder")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try C.addCourse(store, "crs-1")
        for (index, id) in ["lec-a", "lec-b", "lec-c", "lec-d"].enumerated() {
            try C.addLecture(store, id, course: "crs-1", number: index + 1)
        }
        #expect(try Self.lessonOrder(store) == ["lec-a", "lec-b", "lec-c", "lec-d"])
        try F.sendAll(store)

        // Lecture d moves to the front, as an outline save renumbers them.
        try store.execute("UPDATE course_lectures SET lecture_number = lecture_number + 10 WHERE course_id = 'crs-1'")
        for (index, id) in ["lec-d", "lec-a", "lec-b", "lec-c"].enumerated() {
            try store.execute("UPDATE course_lectures SET lecture_number = ? WHERE id = ?", [.integer(Int64(index + 1)), .text(id)])
        }
        try store.keepCourseRowsForGeneration2(courseIDs: ["crs-1"])
        #expect(try Self.lessonOrder(store) == ["lec-d", "lec-a", "lec-b", "lec-c"])
        let pending = try F.pending(store)
        #expect(pending.keys.sorted() == ["Lesson:lec-d"], "one key moved")
        #expect(Set(try #require(pending["Lesson:lec-d"]).stamps.keys.map(\.field)) == ["orderKey"], "a renumbering is no title change")
    }

    @Test("An inbound order rewrites lecture_number, swapping numbers without breaking the course's unique number")
    func inboundOrderRenumbers() throws {
        let (root, store) = try F.makeStore("lesson-inbound")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try C.addCourse(store, "crs-1")
        try C.addLecture(store, "lec-a", course: "crs-1", number: 1)
        try C.addLecture(store, "lec-b", course: "crs-1", number: 2)
        try C.addLecture(store, "lec-c", course: "crs-1", number: 3)
        try F.sendAll(store)
        let keys = try Self.lessonOrder(store).map { try #require(try F.text(store, "SELECT order_key FROM course_lectures WHERE id = ?", [.text($0)])) }
        // Another Mac put lecture a last.
        let last = try FractionalIndex.key(between: keys[2], and: nil)
        try F.apply(store, [try C.lessonRecord("lec-a", course: "crs-1", orderKey: last, title: "Lecture lec-a", ms: 1_800_000_000_000)])
        #expect(try Self.numbers(store) == "lec-a=3,lec-b=1,lec-c=2")
        #expect(try F.pending(store).isEmpty, "the numbers are derived, never sent")
        // A new lesson from another Mac lands between b and c.
        let middle = try FractionalIndex.key(between: keys[1], and: keys[2])
        try F.apply(store, [try C.lessonRecord("lec-n", course: "crs-1", orderKey: middle, title: "New")])
        #expect(try Self.numbers(store) == "lec-a=4,lec-b=1,lec-c=3,lec-n=2")
    }

    @Test("A lesson's items are keyed by sort_index; moving one sends its key alone, and an inbound key rewrites sort_index")
    func itemOrder() throws {
        let (root, store) = try F.makeStore("lesson-items")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try C.addCourse(store, "crs-1")
        try C.addLecture(store, "lec-1", course: "crs-1", number: 1)
        for (index, source) in ["src-a", "src-b", "src-c"].enumerated() {
            try F.addSource(store, source)
            try C.addItem(store, "cli-\(source)", lecture: "lec-1", source: source, sortIndex: index)
        }
        try F.sendAll(store)
        try store.execute("UPDATE course_lecture_items SET sort_index = -1 WHERE id = 'cli-src-c'")
        try C.keep(store, lecture: "lec-1")
        let pending = try F.pending(store)
        #expect(pending.keys.sorted() == ["Entry:\(C.lessonEntryID("lec-1", "src-c"))"])
        try F.sendAll(store)

        // Another Mac moves a to the end.
        let lastKey = try #require(try F.text(store, "SELECT MAX(order_key) FROM course_lecture_items WHERE lecture_id = 'lec-1'"))
        try F.apply(store, [try C.lessonEntryRecord("lec-1", "src-a", role: "video", orderKey: try FractionalIndex.key(between: lastKey, and: nil), ms: 1_800_000_000_000)])
        #expect(try F.text(store, "SELECT group_concat(source_id, ',') FROM (SELECT source_id FROM course_lecture_items WHERE lecture_id = 'lec-1' ORDER BY sort_index)")
                == "src-c,src-b,src-a")
        #expect(try F.pending(store).isEmpty)
    }

    @Test("Two page ranges of one source in one lesson are two Entries, and removing the first renames nothing")
    func twoPageRangesOfOneSource() throws {
        let (root, store) = try F.makeStore("lesson-spans")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try C.addCourse(store, "crs-1")
        try C.addLecture(store, "lec-1", course: "crs-1", number: 1)
        try F.addSource(store, "src-ch")
        try C.addItem(store, "cli-1", lecture: "lec-1", source: "src-ch", role: "reading", sortIndex: 0, pages: 3...9, createdAt: 10)
        try C.addItem(store, "cli-2", lecture: "lec-1", source: "src-ch", role: "reading", sortIndex: 1, pages: 20...31, createdAt: 11)
        let first = C.lessonEntryID("lec-1", "src-ch")
        let second = C.lessonEntryID("lec-1", "src-ch", slot: 2)
        #expect(second == first + "#2")
        var pending = try F.pending(store)
        #expect(F.savedFields(pending["Entry:\(first)"])?["span"] == C.pageSpan(2, 8))
        #expect(F.savedFields(pending["Entry:\(second)"])?["span"] == C.pageSpan(19, 30))
        #expect(F.savedFields(pending["Entry:\(second)"])?["itemID"] == .string("src-ch"), "the item is the source; the slot is only in the name")
        try F.sendAll(store)

        // A third range takes slot 3; the first two keep theirs.
        try C.addItem(store, "cli-3", lecture: "lec-1", source: "src-ch", role: "reading", sortIndex: 2, pages: 40...44, createdAt: 12)
        pending = try F.pending(store)
        #expect(pending.keys.sorted() == ["Entry:\(first)#3"])

        // Removing the first range removes the unsuffixed Entry; #2 and #3 keep their names.
        try F.sendAll(store)
        try store.execute("DELETE FROM course_lecture_items WHERE id = 'cli-1'")
        pending = try F.pending(store)
        #expect(pending.keys.sorted() == ["Entry:\(first)"])
        #expect(F.savedFields(pending["Entry:\(first)"])?["state"] == .string("removed"))
        try F.sendAll(store)
        // A range added later takes the free first slot.
        try C.addItem(store, "cli-4", lecture: "lec-1", source: "src-ch", role: "reading", sortIndex: 3, pages: 50...52, createdAt: 13)
        pending = try F.pending(store)
        #expect(pending.keys.sorted() == ["Entry:\(first)"])
        #expect(F.savedFields(pending["Entry:\(first)"])?["state"] == .string("active"))
        #expect(F.savedFields(pending["Entry:\(first)"])?["span"] == C.pageSpan(49, 51))

        // Another Mac projects both spans of a source into two rows with their units.
        let (otherRoot, other) = try F.makeStore("lesson-spans-other")
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        try F.prepareReplica(other)
        try F.addSource(other, "src-ch")
        try F.sendAll(other)
        try F.apply(other, [
            try C.courseRecord("crs-1"),
            try C.lessonRecord("lec-1", course: "crs-1", orderKey: "a0"),
            try C.lessonEntryRecord("lec-1", "src-ch", slot: 2, orderKey: "a2", span: C.pageSpan(19, 30)),
            try C.lessonEntryRecord("lec-1", "src-ch", orderKey: "a1", span: C.pageSpan(2, 8)),
        ])
        #expect(try F.text(other, """
            SELECT group_concat(span_slot || ':' || locator || ':' || sort_index, ',') FROM (
                SELECT i.span_slot, u.locator, i.sort_index FROM course_lecture_items i JOIN source_units u ON u.id = i.source_unit_id ORDER BY i.span_slot)
        """) == "1:3-9:0,2:20-31:1")
        #expect(try F.text(other, "SELECT group_concat(id, ',') FROM (SELECT id FROM source_units ORDER BY id)")
                == [3...9, 20...31].map { TextbookReading.unitID(sourceID: "src-ch", pages: $0) }.sorted { $0 < $1 }.joined(separator: ","),
                "the units are named as a textbook plan names them")
        #expect(try F.pending(other).isEmpty)
        // A removal of #2 deletes that row only.
        try F.apply(other, [try C.lessonEntryRecord("lec-1", "src-ch", slot: 2, state: "removed", ms: 1_800_000_000_000)])
        #expect(try F.text(other, "SELECT group_concat(COALESCE(span_slot, 1), ',') FROM course_lecture_items") == "1")
    }
}
