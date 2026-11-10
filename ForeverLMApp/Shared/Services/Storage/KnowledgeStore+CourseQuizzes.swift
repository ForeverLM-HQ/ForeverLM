import Foundation
import SQLite3

/// A course's stored quizzes (schema 138, with their symbol and picture since
/// 142; docs/lecture-quiz-design.md). They
/// are part of the course: every write marks the Course record changed, and
/// the quizzes travel inside its payload. Under schema v2 each is a Quiz
/// record of its own (`QuizProjection`), its questions and picture satellites.
extension KnowledgeStore {

    private static let quizSelect = """
        SELECT id, course_id, kind, title, lecture_ids_json, after_lecture_id,
               questions_json, author, created_at, updated_at, symbol, artwork
        FROM course_quizzes
    """

    /// Every stored quiz, or one course's, in no particular order; the
    /// outline orders them (`CourseQuizPlanning.placements`).
    func loadCourseQuizzes(courseID: String? = nil) throws -> [CourseQuiz] {
        var quizzes: [CourseQuiz] = []
        let sql = Self.quizSelect + (courseID == nil ? "" : " WHERE course_id = ?")
        try queryBind(sql, bind: { stmt in
            if let courseID { self.bind(stmt, 1, courseID) }
        }) { stmt in
            if let quiz = self.courseQuiz(from: stmt) { quizzes.append(quiz) }
        }
        return quizzes
    }

    /// The quizzes whose questions' JSON holds any of `texts` — the version
    /// ids of a picture in the image store, say. Matched with `instr`, so
    /// only those rows are decoded; the caller checks each question itself.
    func loadCourseQuizzes(mentioning texts: [String]) throws -> [CourseQuiz] {
        let wanted = Array(Set(texts.filter { !$0.isEmpty })).sorted()
        guard !wanted.isEmpty else { return [] }
        let condition = Array(repeating: "instr(questions_json, ?) > 0", count: wanted.count).joined(separator: " OR ")
        var quizzes: [CourseQuiz] = []
        try queryBind(Self.quizSelect + " WHERE " + condition, bind: { stmt in
            for (offset, text) in wanted.enumerated() { self.bind(stmt, offset + 1, text) }
        }) { stmt in
            if let quiz = self.courseQuiz(from: stmt) { quizzes.append(quiz) }
        }
        return quizzes
    }

    func loadCourseQuiz(_ id: String) throws -> CourseQuiz? {
        var quiz: CourseQuiz?
        try queryBind(Self.quizSelect + " WHERE id = ? LIMIT 1", bind: { stmt in
            self.bind(stmt, 1, id)
        }) { stmt in
            quiz = self.courseQuiz(from: stmt)
        }
        return quiz
    }

    /// Saves a quiz (a new one, or a rewrite of one with the same id) and
    /// queues its course for the other Macs. Under generation 2 a rewrite of
    /// its questions counts a revision (schema v2 §3.5.11).
    func saveCourseQuiz(_ quiz: CourseQuiz) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            var questionsBefore: String?
            questionsBefore = try scalarText("SELECT questions_json FROM course_quizzes WHERE id = ?", [.text(quiz.id)])
            try writeCourseQuizRow(quiz)
            try countQuizRevisionForGeneration2(quizID: quiz.id, questionsBefore: questionsBefore)
            try keepCourseRowsForGeneration2(courseIDs: [quiz.courseID])
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func deleteCourseQuiz(_ id: String) throws {
        guard try loadCourseQuiz(id) != nil else { return }
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("DELETE FROM course_quizzes WHERE id = ?") { stmt in
                self.bind(stmt, 1, id)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Replaces a course's quizzes with the ones its Course record carries,
    /// in one transaction.
    func replaceCourseQuizzesFromSync(courseID: String, quizzes: [CourseQuiz]) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("DELETE FROM course_quizzes WHERE course_id = ?") { stmt in
                self.bind(stmt, 1, courseID)
            }
            for quiz in quizzes where quiz.courseID == courseID {
                try writeCourseQuizRow(quiz)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Part of `deleteCourseGroup`'s transaction: a course's quizzes go with it.
    func deleteCourseQuizzesInCurrentTransaction(courseID: String) throws {
        try execBind("DELETE FROM course_quizzes WHERE course_id = ?") { stmt in
            self.bind(stmt, 1, courseID)
        }
    }

    private func writeCourseQuizRow(_ quiz: CourseQuiz) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let lectureIDs = String(data: try encoder.encode(quiz.lectureIDs), encoding: .utf8),
              let questions = String(data: try encoder.encode(quiz.questions), encoding: .utf8) else {
            throw KnowledgeStoreError.invalidData("Course quiz \(quiz.id) could not be encoded.")
        }
        try execBind("""
            INSERT INTO course_quizzes
                (id, course_id, kind, title, lecture_ids_json, after_lecture_id,
                 questions_json, author, created_at, updated_at, symbol, artwork)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                course_id = excluded.course_id,
                kind = excluded.kind,
                title = excluded.title,
                lecture_ids_json = excluded.lecture_ids_json,
                after_lecture_id = excluded.after_lecture_id,
                questions_json = excluded.questions_json,
                author = excluded.author,
                updated_at = excluded.updated_at,
                symbol = excluded.symbol,
                artwork = excluded.artwork
        """) { stmt in
            self.bind(stmt, 1, quiz.id)
            self.bind(stmt, 2, quiz.courseID)
            self.bind(stmt, 3, quiz.kind.rawValue)
            self.bind(stmt, 4, quiz.title)
            self.bind(stmt, 5, lectureIDs)
            self.bind(stmt, 6, quiz.afterLectureID)
            self.bind(stmt, 7, questions)
            self.bind(stmt, 8, quiz.author.rawValue)
            sqlite3_bind_double(stmt, 9, quiz.createdAt.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 10, quiz.updatedAt.timeIntervalSinceReferenceDate)
            self.bind(stmt, 11, quiz.symbol)
            self.bind(stmt, 12, quiz.artwork)
        }
    }

    private func courseQuiz(from stmt: OpaquePointer?) -> CourseQuiz? {
        guard let id = string(stmt, 0),
              let courseID = string(stmt, 1),
              let kind = string(stmt, 2).flatMap(CourseQuiz.Kind.init(rawValue:)),
              let title = string(stmt, 3) else { return nil }
        let decoder = JSONDecoder()
        let lectureIDs = string(stmt, 4)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? decoder.decode([String].self, from: $0) } ?? []
        let questions = string(stmt, 6)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? decoder.decode([CourseQuizQuestion].self, from: $0) } ?? []
        return CourseQuiz(
            id: id,
            courseID: courseID,
            kind: kind,
            title: title,
            lectureIDs: lectureIDs,
            afterLectureID: string(stmt, 5),
            questions: questions,
            author: string(stmt, 7).flatMap(CourseQuiz.Author.init(rawValue:)) ?? .foreverlm,
            createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 8)),
            updatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 9)),
            symbol: string(stmt, 10),
            artwork: data(stmt, 11)
        )
    }
}

extension KnowledgeStore {
    /// What a chat's course outline is built from (`CourseChatOutline`): the
    /// courses holding any of these sources as lecture material, with their
    /// lectures, materials, quizzes and the materials' titles. Nil when none
    /// of the sources is lecture material, which one indexed read settles.
    func courseChatOutlineMaterial(forSourceIDs sourceIDs: [String]) throws -> CourseChatOutline.Material? {
        let ids = Array(Set(sourceIDs.filter { !$0.isEmpty }))
        guard !ids.isEmpty else { return nil }
        var attachedLectureIDs = Set<String>()
        for chunk in stride(from: 0, to: ids.count, by: 400).map({ Array(ids[$0..<min($0 + 400, ids.count)]) }) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            try queryBind("SELECT lecture_id FROM course_lecture_items WHERE source_id IN (\(placeholders))", bind: { stmt in
                for (index, id) in chunk.enumerated() { self.bind(stmt, index + 1, id) }
            }) { stmt in
                if let lectureID = self.string(stmt, 0) { attachedLectureIDs.insert(lectureID) }
            }
        }
        guard !attachedLectureIDs.isEmpty else { return nil }
        let allLectures = try loadCourseLectures()
        let courseIDs = Set(allLectures.filter { attachedLectureIDs.contains($0.id) }.map(\.courseName))
        guard !courseIDs.isEmpty else { return nil }
        let lectures = allLectures.filter { courseIDs.contains($0.courseName) }
        let lectureIDs = Set(lectures.map(\.id))
        let items = try loadCourseLectureItems().filter { lectureIDs.contains($0.lectureId) }
        let quizzes = try courseIDs.flatMap { try loadCourseQuizzes(courseID: $0) }
        let courses = try loadCourseGroups().filter { courseIDs.contains($0.key) }

        var titles: [String: String] = [:]
        let itemSourceIDs = Array(Set(items.compactMap(\.sourceId)))
        for chunk in stride(from: 0, to: itemSourceIDs.count, by: 400).map({ Array(itemSourceIDs[$0..<min($0 + 400, itemSourceIDs.count)]) }) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            try queryBind("SELECT id, title FROM source_projection WHERE id IN (\(placeholders))", bind: { stmt in
                for (index, id) in chunk.enumerated() { self.bind(stmt, index + 1, id) }
            }) { stmt in
                guard let id = self.string(stmt, 0), let title = self.string(stmt, 1) else { return }
                titles[id] = title
            }
        }
        return CourseChatOutline.Material(
            courses: courses,
            lectures: lectures,
            items: items,
            quizzes: quizzes,
            sourceTitles: titles
        )
    }
}
