import Foundation

// MARK: - The Quiz record (docs/cloudkit-schema-design.md §3.5.11)

/// One `course_quizzes` row as the Quiz record reads it, with the satellites this Mac is still waiting
/// for by role (`QuizSatellites`).
struct QuizRows: Equatable, Sendable {
    let id: String
    let courseID: String
    let kind: String
    let title: String
    let lectureIDs: [String]
    let afterLectureID: String?
    let questionsJSON: String
    let author: String
    let createdAt: Double
    let symbol: String?
    let artwork: Data?
    let revision: Int64
    let waiting: Set<String>
}

/// The Quiz record's projection (§3.5.11): a course's stored quiz. Its questions travel as a satellite
/// (`questions`, the row's `questions_json` as it is, gzip) and its drawn picture as another
/// (`pictures.artwork`, the row's JPEG); each FileRef is laid out from the row, so the bytes behind a
/// pointer can always be read again from the row. `revision` counts changes to the questions under
/// generation 2 (`KnowledgeStore.saveCourseQuiz`), and a sitting records the revision it was taken on.
///
/// The quiz is placed by `lessonID`, the lecture it follows (`after_lecture_id`), and among the
/// quizzes after one lecture by kind, then title (`CourseQuizPlanning.placements`), on every client:
/// today's path has no checkpoint or test lessons and no quiz Entries. A picture a question shows is a
/// `foreverlm://image` address inside the questions (a source's frame or page, or an Artifact picture),
/// so `pictures` holds only the quiz's own drawing. `author` `assistant` is the schema's `learner`
/// (written by an assistant at the learner's ask, `save_course_quiz`).
struct QuizProjection: RecordProjection {
    var recordType: SyncRecordType { .quiz }

    static let columns = [
        "course_id", "kind", "title", "lecture_ids_json", "after_lecture_id", "questions_json", "author", "created_at", "symbol",
        "artwork", "revision",
    ]

    var tables: [ProjectedTable] {
        [ProjectedTable.records(
            "course_quizzes", type: .quiz, syncedColumns: Self.columns,
            parents: [LocalParent("course_id", references: "courses", type: .course, role: .container)]
        )]
    }

    private static func column(_ names: String...) -> FieldFeed { .columns(table: "course_quizzes", names) }

    var feeds: [String: FieldFeed] {
        [
            "courseID": .rowExistence(table: "course_quizzes"), "lessonID": Self.column("after_lecture_id"),
            "coversLessonIDs": Self.column("lecture_ids_json"), "kind": Self.column("kind"), "title": Self.column("title"),
            "symbol": Self.column("symbol"), "author": Self.column("author"), "revision": Self.column("revision"),
            "questionCount": Self.column("questions_json"), "questions": Self.column("questions_json"),
            "pictures": Self.column("artwork"), "createdAt": Self.column("created_at"),
        ]
    }

    /// A deleted quiz deletes the record; its sittings and cards stay (§5.5).
    var missingRow: MissingRowOutcome { .delete }

    static func wireAuthor(_ local: String) -> String { local == "assistant" ? "learner" : local }
    static func localAuthor(_ wire: String) -> String { wire == "learner" ? "assistant" : wire }

    func loadRows(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws -> QuizRows? {
        var rows: QuizRows?
        let waiting = try QuizSatellites.waiting(quizID: record.localID, connection: connection)
        try connection.query("""
            SELECT course_id, kind, title, lecture_ids_json, after_lecture_id, questions_json, author, created_at, symbol, artwork, revision
            FROM course_quizzes WHERE id = ?
        """, [.text(record.localID)]) { row in
            let lectures = (row.text(3).flatMap { try? SyncJSON(parsing: Data($0.utf8)) }?.arrayValue ?? []).compactMap(\.stringValue)
            rows = QuizRows(
                id: record.localID, courseID: row.text(0) ?? "", kind: row.text(1) ?? "practice", title: row.text(2) ?? "",
                lectureIDs: lectures, afterLectureID: row.text(4), questionsJSON: row.text(5) ?? "[]", author: row.text(6) ?? "foreverlm",
                createdAt: row.real(7) ?? 0, symbol: row.text(8), artwork: row.blob(9), revision: row.integer(10) ?? 1,
                waiting: Set(waiting.keys)
            )
        }
        return rows
    }

    static func encodeRows(_ rows: QuizRows) -> [String: SyncJSON] {
        var fields: [String: SyncJSON] = [
            "courseID": .string(rows.courseID),
            "lessonID": rows.afterLectureID.map(SyncJSON.string) ?? .null,
            "coversLessonIDs": .object(Dictionary(rows.lectureIDs.map { ($0, SyncJSON.bool(true)) }, uniquingKeysWith: { first, _ in first })),
            "kind": .string(rows.kind),
            "title": .string(rows.title),
            "symbol": rows.symbol.map(SyncJSON.string) ?? .null,
            "author": .string(wireAuthor(rows.author)),
            "revision": SyncJSON(rows.revision),
            "createdAt": SyncJSON(SyncTime.milliseconds(cocoaSeconds: rows.createdAt)),
        ]
        // What this Mac still waits to fetch is not its to send: the record keeps what it holds.
        if !rows.waiting.contains(QuizSatellites.questionsRole), let file = QuizSatellites.questionsFile(quizID: rows.id, json: rows.questionsJSON) {
            fields["questions"] = file.value
            fields["questionCount"] = SyncJSON((try? SyncJSON(parsing: Data(rows.questionsJSON.utf8)))?.arrayValue?.count ?? 0)
        }
        if !rows.waiting.contains(QuizSatellites.artworkRole) {
            var pictures: [String: SyncJSON] = [:]
            if let artwork = rows.artwork, let file = QuizSatellites.artworkFile(quizID: rows.id, jpeg: artwork) {
                pictures[QuizSatellites.artworkKey] = file.value
            }
            fields["pictures"] = .object(pictures)
        }
        return fields
    }

    func apply(_ envelope: SyncEnvelope, to record: ProjectionRecordRef, connection: SQLiteConnection) throws -> ProjectionApplyOutcome {
        guard !record.zone.isSpace else { return .projected }
        let fields = envelope.fields
        guard let courseID = fields["courseID"]?.stringValue else { return .projected }
        guard try connection.scalarInteger("SELECT EXISTS(SELECT 1 FROM courses WHERE id = ?)", [.text(courseID)]) == 1 else {
            return .waiting([WaitingParent(type: .course, wireID: courseID)])
        }
        let id = record.localID
        var values: [String: SQLiteValue] = [:]
        if let kind = fields["kind"]?.stringValue { values["kind"] = .text(kind) }
        if let title = fields["title"]?.stringValue { values["title"] = .text(title) }
        if let lesson = fields["lessonID"] { values["after_lecture_id"] = .text(lesson.stringValue) }
        if let covers = fields["coversLessonIDs"]?.objectValue {
            let ids = covers.compactMap { $0.value.boolValue == true ? $0.key : nil }
            values["lecture_ids_json"] = .text(String(decoding: SyncJSON.array(try Self.inCourseOrder(ids, courseID: courseID, connection: connection).map(SyncJSON.string)).serialized(), as: UTF8.self))
        }
        if let symbol = fields["symbol"] { values["symbol"] = .text(symbol.stringValue) }
        if let author = fields["author"]?.stringValue { values["author"] = .text(Self.localAuthor(author)) }
        if let revision = fields["revision"]?.int64Value { values["revision"] = .integer(revision) }
        let created = fields["createdAt"]?.int64Value.map { SyncTime.cocoaSeconds(milliseconds: $0) }
        let edited = fields["editedAt"]?.int64Value.map { SyncTime.cocoaSeconds(milliseconds: $0) }
        if let created { values["created_at"] = .real(created) }
        if let edited { values["updated_at"] = .real(edited) }

        let held = try connection.scalarInteger("SELECT EXISTS(SELECT 1 FROM course_quizzes WHERE id = ?)", [.text(id)]) == 1
        if held {
            if !values.isEmpty {
                let names = values.keys.sorted()
                try connection.execute(
                    "UPDATE course_quizzes SET \(names.map { "\($0) = ?" }.joined(separator: ", ")) WHERE id = ?",
                    names.compactMap { values[$0] } + [.text(id)]
                )
            }
        } else {
            let now = Date().timeIntervalSinceReferenceDate
            values["course_id"] = .text(courseID)
            values["kind"] = values["kind"] ?? .text("practice")
            values["title"] = values["title"] ?? .text("")
            values["created_at"] = values["created_at"] ?? .real(created ?? now)
            values["updated_at"] = values["updated_at"] ?? .real(edited ?? created ?? now)
            let names = values.keys.sorted()
            try connection.execute(
                "INSERT INTO course_quizzes (id, \(names.joined(separator: ", "))) VALUES (?, \(names.map { _ in "?" }.joined(separator: ", ")))",
                [.text(id)] + names.compactMap { values[$0] }
            )
        }
        try QuizSatellites.take(fields, quizID: id, connection: connection)
        return .projected
    }

    func applyDeletion(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws {
        guard !record.zone.isSpace else { return }
        try connection.execute("DELETE FROM course_quizzes WHERE id = ?", [.text(record.localID)])
        try QuizSatellites.forget(quizID: record.localID, connection: connection)
    }

    /// The lectures a quiz covers in the course's order (`lecture_ids_json` keeps them in course order;
    /// the record holds a set); a lecture not here yet follows, by id.
    static func inCourseOrder(_ ids: [String], courseID: String, connection: SQLiteConnection) throws -> [String] {
        var numbers: [String: Int64] = [:]
        try connection.query("SELECT id, lecture_number FROM course_lectures WHERE course_id = ?", [.text(courseID)]) { row in
            if let id = row.text(0) { numbers[id] = row.integer(1) }
        }
        return ids.sorted { (numbers[$0] ?? .max, $0) < (numbers[$1] ?? .max, $1) }
    }
}

// MARK: - A quiz's satellites on this Mac (§3.5.30)

/// A quiz's two satellites: its questions (role `questions`, gzip JSON) and its drawn picture (role
/// `picture.artwork`, the JPEG). The FileRef is laid out from the row as `BlobStore.upload` lays it
/// out on a native client, owned by the quiz, so its bytes are the row's at any time and the uploader
/// needs no staged copy.
///
/// An inbound FileRef whose bytes this Mac does not hold is remembered in `ck_backfill_queue` (kind
/// `quizSatellites`, the quiz's id, the wanted FileRefs by role) for the satellite reader, and the
/// encoder holds that field back meanwhile, so a local edit of the quiz never sends the old questions
/// over the new ones. `received` writes the fetched bytes in and forgets the wish.
enum QuizSatellites {
    static let queueKind = "quizSatellites"
    static let questionsRole = "questions"
    static let artworkKey = "artwork"
    static let artworkRole = "picture." + artworkKey

    static func questionsFile(quizID: String, json: String) -> FileRef? {
        layout(quizID: quizID, role: questionsRole, mime: "application/json", encoding: .gzip, body: Data(json.utf8))
    }

    static func artworkFile(quizID: String, jpeg: Data) -> FileRef? {
        layout(quizID: quizID, role: artworkRole, mime: "image/jpeg", encoding: .identity, body: jpeg)
    }

    private static func layout(quizID: String, role: String, mime: String, encoding: BlobStore.Encoding, body: Data) -> FileRef? {
        let satellite = SourceLocalSatellite(map: .files, role: role, mime: mime, encoding: encoding, body: body, localPath: nil, input: nil)
        return try? SourceSatelliteLayout.layout(satellite, owner: quizID).file
    }

    /// The FileRefs this Mac waits to fetch for a quiz, by role.
    static func waiting(quizID: String, connection: SQLiteConnection) throws -> [String: SyncJSON] {
        let json = try connection.scalarText("SELECT payload_json FROM ck_backfill_queue WHERE kind = ? AND target = ?", [.text(queueKind), .text(quizID)])
        return json.flatMap { try? SyncJSON(parsing: Data($0.utf8)) }?.objectValue ?? [:]
    }

    /// Takes an inbound record's satellites: a FileRef this Mac's bytes match needs nothing; one they do
    /// not is waited for; a picture the record no longer holds is cleared.
    static func take(_ fields: [String: SyncJSON], quizID: String, connection: SQLiteConnection) throws {
        var waiting = try self.waiting(quizID: quizID, connection: connection)
        var bytes: (questions: Data, artwork: Data?) = (Data(), nil)
        try connection.query("SELECT questions_json, artwork FROM course_quizzes WHERE id = ?", [.text(quizID)]) { row in
            bytes = (Data((row.text(0) ?? "").utf8), row.blob(1))
        }
        if let questions = fields["questions"].flatMap(FileRef.init(json:)) {
            waiting[questionsRole] = questions.hash == SyncIdentity.sha256Hex(bytes.questions) ? nil : questions.value
        }
        if let pictures = fields["pictures"] {
            if let artwork = pictures[artworkKey].flatMap(FileRef.init(json:)) {
                waiting[artworkRole] = artwork.hash == bytes.artwork.map(SyncIdentity.sha256Hex) ? nil : artwork.value
            } else {
                waiting[artworkRole] = nil
                try connection.execute("UPDATE course_quizzes SET artwork = NULL WHERE id = ? AND artwork IS NOT NULL", [.text(quizID)])
            }
        }
        try save(waiting, quizID: quizID, connection: connection)
    }

    /// The satellite reader's half: the fetched bytes of `role` written into the quiz's row, and the
    /// wish forgotten. Runs under the apply guard, like any projection write.
    static func received(_ body: Data, role: String, quizID: String, connection: SQLiteConnection) throws {
        var waiting = try self.waiting(quizID: quizID, connection: connection)
        switch role {
        case questionsRole:
            try connection.execute("UPDATE course_quizzes SET questions_json = ? WHERE id = ?", [.text(String(decoding: body, as: UTF8.self)), .text(quizID)])
        case artworkRole:
            try connection.execute("UPDATE course_quizzes SET artwork = ? WHERE id = ?", [.blob(body), .text(quizID)])
        default:
            return
        }
        waiting[role] = nil
        try save(waiting, quizID: quizID, connection: connection)
    }

    static func forget(quizID: String, connection: SQLiteConnection) throws {
        try connection.execute("DELETE FROM ck_backfill_queue WHERE kind = ? AND target = ?", [.text(queueKind), .text(quizID)])
    }

    private static func save(_ waiting: [String: SyncJSON], quizID: String, connection: SQLiteConnection) throws {
        guard !waiting.isEmpty else { return try forget(quizID: quizID, connection: connection) }
        try connection.execute("""
            INSERT INTO ck_backfill_queue (kind, target, payload_json, enqueued_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(kind, target) DO UPDATE SET payload_json = excluded.payload_json
        """, [
            .text(queueKind), .text(quizID), .text(String(decoding: SyncJSON.object(waiting).serialized(), as: UTF8.self)),
            .real(Date().timeIntervalSinceReferenceDate),
        ])
    }
}
