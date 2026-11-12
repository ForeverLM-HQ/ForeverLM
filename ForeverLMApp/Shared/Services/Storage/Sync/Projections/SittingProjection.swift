import Foundation

// MARK: - Sitting (docs/cloudkit-schema-design.md §3.5.23)

/// This device's sync device id, from its stamp clock (`ck_clock`); nil before the clock exists. A row
/// this Mac writes before then carries '' and is claimed when the clock is made (`claimOwnMemoryRows`).
enum MemorySyncDevice {
    static func current(_ connection: SQLiteConnection) throws -> String? {
        guard let json = try connection.scalarText("SELECT clock_json FROM ck_clock WHERE id = 1") else { return nil }
        return (try? JSONDecoder().decode(StampClock.self, from: Data(json.utf8)))?.deviceID
    }
}

/// A Sitting's local rows: a sitting with its answers (`memory_sittings`, `memory_sitting_answers`), or a
/// learning bout (`learning_bouts`), which is the Sitting of kind `bout` (§10).
enum SittingRows: Equatable, Sendable {
    struct Sitting: Equatable, Sendable {
        var id: String
        var deviceID: String
        var kind: String
        var scope: SyncJSON?
        var startedAt: Double
        var endedAt: Double?
        var chatID: String?
        var part: Int64
        var result: SyncJSON?
        var writeUp: SyncJSON?
        var breakMinutes: Int64?
        var breakEndsAt: Double?
        var abandonedAt: Double?
        var answers: [String: SyncJSON]
    }

    struct Bout: Equatable, Sendable {
        var id: String
        var deviceID: String?
        var title: String
        var notebookID: String?
        var sourceIDs: [String]
        var plannedMinutes: Int64
        var blockID: String?
        var startedAt: Double
        var endedAt: Double?
        var learned: String?
        var unclear: String?
        var writtenAt: Double?
        var breakMinutes: Int64
        var breakStartedAt: Double?
        var abandonedAt: Double?
    }

    case sitting(Sitting)
    case bout(Bout)
}

/// The Sitting record's projection. A Sitting has one writer (§6.1): this Mac sends only its own
/// sittings (its device id, or '' before it knew it) and the migrated `legacy22` history the seeder
/// sends; another device's sitting is projected here and never sent back. An answer is written once
/// (S per element), so answers are inserted and never rewritten. History is append-only: a missing
/// local row never deletes the record (P8).
struct SittingProjection: RecordProjection {
    var recordType: SyncRecordType { .sitting }

    static let sittingColumns = [
        "device_id", "kind", "scope_json", "started_at", "ended_at", "chat_id", "part", "result_json", "write_up_json",
        "break_minutes", "break_ends_at", "abandoned_at",
    ]
    static let boutColumns = [
        "title", "notebook_id", "source_ids", "planned_minutes", "block_id", "started_at", "ended_at", "learned", "unclear",
        "written_at", "break_minutes", "break_started_at", "abandoned_at",
    ]

    var tables: [ProjectedTable] {
        let sittingSQL: @Sendable (String) -> String = { "\($0).sitting_id" }
        return [
            .records("memory_sittings", type: .sitting, syncedColumns: Self.sittingColumns),
            ProjectedTable(
                "memory_sitting_answers", localKey: ["answer_id"], keyColumns: ["sitting_id"],
                syncedColumns: ["subject", "at", "counted", "practice", "answer_json"], elementColumn: "answer_id",
                recordTypes: [.sitting],
                record: { values in
                    values["sitting_id"]?.textValue.map { RowRecord(type: .sitting, localID: $0, personalID: $0) }
                },
                localIDSQL: sittingSQL, personalIDSQL: sittingSQL
            ),
            .records("learning_bouts", type: .sitting, syncedColumns: Self.boutColumns),
        ]
    }

    private static func either(_ sitting: [String], _ bout: [String]) -> FieldFeed {
        .anyOf([.columns(table: "memory_sittings", sitting), .columns(table: "learning_bouts", bout)])
    }

    var feeds: [String: FieldFeed] {
        [
            "answers": .elementRows(table: "memory_sitting_answers"),
            "endedAt": Self.either(["ended_at"], ["ended_at"]),
            "result": .columns(table: "memory_sittings", ["result_json"]),
            "writeUp": Self.either(["write_up_json"], ["learned", "unclear", "written_at"]),
            "breakMinutes": Self.either(["break_minutes"], ["break_minutes"]),
            "breakEndsAt": Self.either(["break_ends_at"], ["break_started_at", "break_minutes"]),
            "abandonedAt": Self.either(["abandoned_at"], ["abandoned_at"]),
        ]
    }

    var missingRow: MissingRowOutcome { .fields([:]) }
    var missingParentNeverDeletes: Bool { true }
    var priority: OutboxPriority { .personal }
    /// A sitting is saved at most every 30 s while it runs (D44).
    var debounce: TimeInterval { 30 }

    func loadRows(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws -> SittingRows? {
        let device = try MemorySyncDevice.current(connection)
        if var sitting = try Self.loadSitting(id: record.localID, connection: connection) {
            // One writer: this Mac sends its own sittings and the migrated history, never another device's.
            guard sitting.deviceID.isEmpty || sitting.deviceID == device || sitting.deviceID == SyncIdentity.migratedHistoryDeviceID else { return nil }
            if sitting.deviceID.isEmpty {
                guard let device else { return nil }
                sitting.deviceID = device
            }
            return .sitting(sitting)
        }
        guard var bout = try Self.loadBout(id: record.localID, connection: connection) else { return nil }
        // A bout brought in from another device stays that device's (one writer, S): a local touch of its
        // row never re-sends it under this Mac's id.
        if let store = connection as? KnowledgeStore,
           let held = try store.replica.record(zoneKey: record.zoneKey, recordType: SyncRecordType.sitting.rawValue, wireID: record.wireID),
           let writer = (try? SyncEnvelope(storedPayload: held.payload))?.fields["deviceID"]?.stringValue,
           !writer.isEmpty, writer != device, writer != SyncIdentity.migratedHistoryDeviceID { return nil }
        bout.deviceID = device
        return .bout(bout)
    }

    static func loadSitting(id: String, connection: SQLiteConnection) throws -> SittingRows.Sitting? {
        var sitting: SittingRows.Sitting?
        try connection.query("""
            SELECT device_id, kind, scope_json, started_at, ended_at, chat_id, part, result_json, write_up_json,
                   break_minutes, break_ends_at, abandoned_at
            FROM memory_sittings WHERE id = ?
        """, [.text(id)]) { row in
            sitting = SittingRows.Sitting(
                id: id, deviceID: row.text(0) ?? "", kind: row.text(1) ?? "cards", scope: Self.json(row.text(2)),
                startedAt: row.real(3) ?? 0, endedAt: row.real(4), chatID: row.text(5), part: row.integer(6) ?? 1,
                result: Self.json(row.text(7)), writeUp: Self.json(row.text(8)), breakMinutes: row.integer(9),
                breakEndsAt: row.real(10), abandonedAt: row.real(11), answers: [:]
            )
        }
        guard var found = sitting else { return nil }
        try connection.query("SELECT answer_id, answer_json FROM memory_sitting_answers WHERE sitting_id = ?", [.text(id)]) { row in
            if let answerID = row.text(0), let answer = Self.json(row.text(1)) { found.answers[answerID] = answer }
        }
        return found
    }

    static func loadBout(id: String, connection: SQLiteConnection) throws -> SittingRows.Bout? {
        var bout: SittingRows.Bout?
        try connection.query("""
            SELECT title, notebook_id, source_ids, planned_minutes, block_id, started_at, ended_at, learned, unclear,
                   written_at, break_minutes, break_started_at, abandoned_at
            FROM learning_bouts WHERE id = ?
        """, [.text(id)]) { row in
            bout = SittingRows.Bout(
                id: id, deviceID: nil, title: row.text(0) ?? "", notebookID: row.text(1),
                sourceIDs: KnowledgeStore.sourceIDList(fromJSON: row.text(2)), plannedMinutes: row.integer(3) ?? 0,
                blockID: row.text(4), startedAt: row.real(5) ?? 0, endedAt: row.real(6), learned: row.text(7),
                unclear: row.text(8), writtenAt: row.real(9), breakMinutes: row.integer(10) ?? 0,
                breakStartedAt: row.real(11), abandonedAt: row.real(12)
            )
        }
        // A bout names its sources by wire id on the record (§4.3), whichever copy it was run on.
        if let store = connection as? KnowledgeStore, var found = bout {
            found.sourceIDs = try found.sourceIDs.map { try store.personalStateSourceKey($0) }
            bout = found
        }
        return bout
    }

    static func json(_ text: String?) -> SyncJSON? { SyncJSON.stored(text) }

    static func text(_ json: SyncJSON?) -> String? { SyncJSON.storedText(json) }

    static func milliseconds(_ seconds: Double?) -> SyncJSON? {
        seconds.map { SyncJSON(SyncTime.milliseconds(cocoaSeconds: $0)) }
    }

    static func encodeRows(_ rows: SittingRows) -> [String: SyncJSON] {
        var fields: [String: SyncJSON] = [:]
        switch rows {
        case .sitting(let sitting):
            fields["deviceID"] = .string(sitting.deviceID)
            fields["kind"] = .string(sitting.kind)
            fields["startedAt"] = milliseconds(sitting.startedAt)
            fields["part"] = SyncJSON(sitting.part)
            if let scope = sitting.scope { fields["scope"] = scope }
            if let endedAt = milliseconds(sitting.endedAt) { fields["endedAt"] = endedAt }
            if let chatID = sitting.chatID { fields["chatID"] = .string(chatID) }
            if let result = sitting.result { fields["result"] = result }
            if let writeUp = sitting.writeUp { fields["writeUp"] = writeUp }
            if let minutes = sitting.breakMinutes { fields["breakMinutes"] = SyncJSON(minutes) }
            if let endsAt = milliseconds(sitting.breakEndsAt) { fields["breakEndsAt"] = endsAt }
            if let abandonedAt = milliseconds(sitting.abandonedAt) { fields["abandonedAt"] = abandonedAt }
            fields["answers"] = .object(sitting.answers)

        case .bout(let bout):
            if let device = bout.deviceID { fields["deviceID"] = .string(device) }
            fields["kind"] = "bout"
            fields["startedAt"] = milliseconds(bout.startedAt)
            fields["part"] = 1
            // The bout's notebook, and what the learner set it up with: its title, planned minutes,
            // sources and block, kept in the scope it started with.
            var scope: [String: SyncJSON] = ["title": .string(bout.title), "plannedMinutes": SyncJSON(bout.plannedMinutes)]
            if let notebookID = bout.notebookID { scope["notebookID"] = .string(notebookID) }
            if !bout.sourceIDs.isEmpty { scope["sourceIDs"] = .array(bout.sourceIDs.map(SyncJSON.string)) }
            if let blockID = bout.blockID { scope["blockID"] = .string(blockID) }
            fields["scope"] = .object(scope)
            if let endedAt = milliseconds(bout.endedAt) { fields["endedAt"] = endedAt }
            if bout.writtenAt != nil || bout.learned != nil || bout.unclear != nil {
                var writeUp: [String: SyncJSON] = ["learned": .string(bout.learned ?? ""), "unclear": .string(bout.unclear ?? "")]
                if let writtenAt = milliseconds(bout.writtenAt) { writeUp["writtenAt"] = writtenAt }
                fields["writeUp"] = .object(writeUp)
            }
            if bout.writtenAt != nil || bout.breakMinutes > 0 { fields["breakMinutes"] = SyncJSON(bout.breakMinutes) }
            if let start = bout.breakStartedAt {
                fields["breakEndsAt"] = milliseconds(start + Double(bout.breakMinutes) * 60)
            }
            if let abandonedAt = milliseconds(bout.abandonedAt) { fields["abandonedAt"] = abandonedAt }
        }
        return fields
    }

    // MARK: Inbound

    func apply(_ envelope: SyncEnvelope, to record: ProjectionRecordRef, connection: SQLiteConnection) throws -> ProjectionApplyOutcome {
        // Per-member history: never in a space (§3.5.23).
        guard !record.zone.isSpace else { return .projected }
        let fields = envelope.fields
        let isBout = try fields["kind"]?.stringValue == "bout"
            || (fields["kind"] == nil && Self.loadBout(id: record.localID, connection: connection) != nil)
        if isBout {
            try Self.applyBout(fields, id: record.localID, connection: connection)
        } else {
            try Self.applySitting(fields, id: record.localID, connection: connection)
        }
        return .projected
    }

    static func seconds(_ value: SyncJSON?) -> Double? {
        value?.int64Value.map { SyncTime.cocoaSeconds(milliseconds: $0) }
    }

    private static func applySitting(_ fields: [String: SyncJSON], id: String, connection: SQLiteConnection) throws {
        let held = try loadSitting(id: id, connection: connection)
        func value(_ field: String, _ held: SyncJSON?) -> SyncJSON? {
            guard let given = fields[field] else { return held }
            return given.isNull ? nil : given
        }
        func time(_ field: String, _ held: Double?) -> Double? {
            guard let given = fields[field] else { return held }
            return seconds(given)
        }
        let device = fields["deviceID"]?.stringValue ?? held?.deviceID ?? ""
        let kind = fields["kind"]?.stringValue ?? held?.kind ?? "cards"
        let startedAt = time("startedAt", held?.startedAt) ?? 0
        try connection.execute("""
            INSERT INTO memory_sittings (id, device_id, kind, scope_json, started_at, ended_at, chat_id, part, result_json,
                write_up_json, break_minutes, break_ends_at, abandoned_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                device_id = excluded.device_id, kind = excluded.kind, scope_json = excluded.scope_json,
                started_at = excluded.started_at, ended_at = excluded.ended_at, chat_id = excluded.chat_id,
                part = excluded.part, result_json = excluded.result_json, write_up_json = excluded.write_up_json,
                break_minutes = excluded.break_minutes, break_ends_at = excluded.break_ends_at,
                abandoned_at = excluded.abandoned_at
        """, [
            .text(id), .text(device), .text(kind), .text(text(value("scope", held?.scope))), .real(startedAt),
            .real(time("endedAt", held?.endedAt)), .text(value("chatID", held?.chatID.map(SyncJSON.string))?.stringValue),
            .integer(value("part", held.map { SyncJSON($0.part) })?.int64Value ?? 1),
            .text(text(value("result", held?.result))), .text(text(value("writeUp", held?.writeUp))),
            .integer(value("breakMinutes", held?.breakMinutes.map { SyncJSON($0) })?.int64Value),
            .real(time("breakEndsAt", held?.breakEndsAt)), .real(time("abandonedAt", held?.abandonedAt)),
        ])

        // Answers are written once each (S per element): a held one is never rewritten.
        let chatID = value("chatID", held?.chatID.map(SyncJSON.string))?.stringValue
        var cards = Set<String>()
        for (answerID, answer) in (fields["answers"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let object = answer.objectValue, let subject = object["subject"]?.stringValue else { continue }
            let at = seconds(object["at"]) ?? startedAt
            try connection.execute("""
                INSERT INTO memory_sitting_answers (answer_id, sitting_id, subject, at, counted, practice, answer_json)
                VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(answer_id) DO NOTHING
            """, [
                .text(answerID), .text(id), .text(subject), .real(at), .integer(object["counted"]?.boolValue == false ? 0 : 1),
                .integer(object["practice"]?.boolValue == true ? 1 : 0), .text(text(answer)),
            ])
            // Only an answer this Mac did not hold becomes an attempt: one the learner deleted here stays
            // deleted when its Sitting arrives again (the answer row outlives its attempt).
            guard connection.changedRowCount > 0 else { continue }
            if let attempt = MemoryAnswerCodec.attempt(answerID: answerID, answer: object, sessionID: chatID) {
                try MemoryAnswerCodec.insertAttempt(attempt.attempt, fingerprint: attempt.fingerprint, connection: connection)
                cards.insert(attempt.attempt.memoryItemID)
            }
        }
        if let store = connection as? KnowledgeStore {
            for card in cards.sorted() { try store.rebuildMemorySchedule(memoryItemID: card) }
        }
    }

    private static func applyBout(_ fields: [String: SyncJSON], id: String, connection: SQLiteConnection) throws {
        let held = try loadBout(id: id, connection: connection)
        let scope = fields["scope"]?.objectValue ?? [:]
        let writeUp = fields["writeUp"]?.objectValue
        let startedAt = seconds(fields["startedAt"]) ?? held?.startedAt ?? Date().timeIntervalSinceReferenceDate
        let breakMinutes = fields["breakMinutes"]?.int64Value ?? held?.breakMinutes ?? 0
        var breakStartedAt = held?.breakStartedAt
        if let endsAt = seconds(fields["breakEndsAt"]) { breakStartedAt = endsAt - Double(breakMinutes) * 60 }
        let sourceIDs = scope["sourceIDs"]?.arrayValue?.compactMap(\.stringValue) ?? held?.sourceIDs ?? []
        let sourceIDsText = String(decoding: SyncJSON.array(sourceIDs.map(SyncJSON.string)).serialized(), as: UTF8.self)
        // A bout lives with the day it started on (`learning_bouts.day_plan_id`).
        let day = DayPlan.dateString(for: Date(timeIntervalSinceReferenceDate: startedAt))
        let now = Date().timeIntervalSinceReferenceDate
        try connection.execute("""
            INSERT INTO day_plans (id, plan_date, created_at, updated_at) VALUES (?, ?, ?, ?) ON CONFLICT(id) DO NOTHING
        """, [.text(day), .text(day), .real(now), .real(now)])
        try connection.execute("""
            INSERT INTO learning_bouts (id, day_plan_id, block_id, title, notebook_id, source_ids, planned_minutes, started_at,
                ended_at, learned, unclear, written_at, break_minutes, break_started_at, abandoned_at, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                block_id = excluded.block_id, title = excluded.title, notebook_id = excluded.notebook_id,
                source_ids = excluded.source_ids, planned_minutes = excluded.planned_minutes,
                started_at = excluded.started_at, ended_at = excluded.ended_at, learned = excluded.learned,
                unclear = excluded.unclear, written_at = excluded.written_at, break_minutes = excluded.break_minutes,
                break_started_at = excluded.break_started_at, abandoned_at = excluded.abandoned_at,
                updated_at = excluded.updated_at
        """, [
            .text(id), .text(day), .text(scope["blockID"]?.stringValue ?? held?.blockID),
            .text(scope["title"]?.stringValue ?? held?.title ?? ""), .text(scope["notebookID"]?.stringValue ?? held?.notebookID),
            .text(sourceIDsText), .integer(scope["plannedMinutes"]?.int64Value ?? held?.plannedMinutes ?? Int64(LearningBout.defaultMinutes)),
            .real(startedAt), .real(fields["endedAt"].map { seconds($0) } ?? held?.endedAt),
            .text(writeUp.map { $0["learned"]?.stringValue } ?? held?.learned),
            .text(writeUp.map { $0["unclear"]?.stringValue } ?? held?.unclear),
            .real(writeUp.map { seconds($0["writtenAt"]) } ?? held?.writtenAt),
            .integer(breakMinutes), .real(breakStartedAt),
            .real(fields["abandonedAt"].map { seconds($0) } ?? held?.abandonedAt),
            .real(startedAt), .real(now),
        ])
    }

    func applyDeletion(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws {
        guard !record.zone.isSpace else { return }
        // The record's own rows go; the attempts its answers became stay generation-1 history.
        try connection.execute("DELETE FROM memory_sitting_answers WHERE sitting_id = ?", [.text(record.localID)])
        try connection.execute("DELETE FROM memory_sittings WHERE id = ?", [.text(record.localID)])
        try connection.execute("DELETE FROM learning_bouts WHERE id = ?", [.text(record.localID)])
    }
}

// MARK: - Answers ↔ attempts

/// A card answer and the `memory_attempts` row it is, both ways. The answer is the web's shape
/// (`library-mutations-v2.js`), plus what only the Mac records, under keys the
/// web leaves alone: the exchange the attempt was made in, a discovery or import, the grading error
/// and the model's metadata.
enum MemoryAnswerCodec {
    static func answer(for attempt: MemoryAttempt, curriculumFingerprint: String?) -> SyncJSON {
        var answer: [String: SyncJSON] = [
            "subject": .string("crd:" + attempt.memoryItemID),
            "at": SyncJSON(SyncTime.milliseconds(attempt.attemptedAt)),
            "prompt": .string(attempt.prompt),
            "response": .string(attempt.learnerAnswer),
            "counted": .bool(attempt.gradeState == .graded),
            "practice": false,
            "gradeState": .string(attempt.gradeState.rawValue),
        ]
        if let rating = attempt.scheduleRating {
            answer["rating"] = .string(rating.rawValue)
            if attempt.gradeState == .graded { answer["outcome"] = .string("graded:" + rating.rawValue) }
        }
        if let score = attempt.score { answer["score"] = .number(score) }
        if let feedback = attempt.feedback, !feedback.isEmpty { answer["feedback"] = .string(feedback) }
        if let evidence = attempt.evidenceJSON.flatMap({ try? SyncJSON(parsing: Data($0.utf8)) }) { answer["evidence"] = evidence }
        if let modelID = attempt.modelID {
            answer["model"] = ["provider": attempt.modelProvider.map(SyncJSON.string) ?? .null, "id": .string(modelID)]
        }
        if let curriculumFingerprint { answer["curriculumFingerprint"] = .string(curriculumFingerprint) }
        if let exchangeID = attempt.exchangeID { answer["exchangeID"] = .string(exchangeID) }
        if attempt.attemptType != .review { answer["attemptType"] = .string(attempt.attemptType.rawValue) }
        if let error = attempt.gradingError { answer["gradingError"] = .string(error) }
        if let metadata = attempt.modelMetadataJSON { answer["modelMetadata"] = .string(metadata) }
        return .object(answer)
    }

    /// The attempt an answer about a card is, with the curriculum it was given against; nil for an answer
    /// about anything else, and for one that only practised (no grade state and not counted), which
    /// generation 1 never recorded.
    static func attempt(answerID: String, answer: [String: SyncJSON], sessionID: String?) -> (attempt: MemoryAttempt, fingerprint: String?)? {
        guard let subject = answer["subject"]?.stringValue,
              let cardID = CardScheduleAnswer(answerID: answerID, subject: subject, at: 0).cardID,
              let at = answer["at"]?.int64Value
        else { return nil }
        let stated = answer["gradeState"]?.stringValue.flatMap(MemoryGradeState.init(rawValue:))
        if stated == nil, answer["counted"]?.boolValue == false { return nil }
        let rating = answer["rating"]?.stringValue.flatMap(MemoryScheduleRating.init(rawValue:))
        let gradeState = stated ?? (rating == nil ? .pending : .graded)
        let outcome = answer["outcome"]?.stringValue
        let selfGraded = outcome == "remembered" || outcome == "forgot"
        var score: Double?
        if gradeState == .graded {
            score = answer["score"]?.numberValue
                ?? answer["correct"]?.boolValue.map { $0 ? 1 : 0 }
                ?? (selfGraded ? (outcome == "remembered" ? 1 : 0) : rating.map { $0 == .again ? 0 : 1 })
            if let value = score, !(0...1).contains(value) { score = nil }
        }
        let response = answer["response"]?.stringValue ?? ((selfGraded || gradeState == .graded) ? "(self-graded)" : "")
        let model = answer["model"]?.objectValue
        let attempt = MemoryAttempt(
            id: answerID, memoryItemID: cardID, sessionID: sessionID, exchangeID: answer["exchangeID"]?.stringValue,
            attemptType: answer["attemptType"]?.stringValue.flatMap(MemoryAttemptType.init(rawValue:)) ?? .review,
            prompt: answer["prompt"]?.stringValue ?? "", learnerAnswer: response, feedback: answer["feedback"]?.stringValue,
            score: score, scheduleRating: gradeState == .graded ? rating : nil, gradeState: gradeState,
            gradingError: answer["gradingError"]?.stringValue,
            evidenceJSON: answer["evidence"].flatMap { $0.isNull ? nil : String(decoding: $0.serialized(), as: UTF8.self) },
            attemptedAt: SyncTime.date(milliseconds: at), modelProvider: model?["provider"]?.stringValue,
            modelID: model?["id"]?.stringValue, modelMetadataJSON: answer["modelMetadata"]?.stringValue
        )
        return (attempt, answer["curriculumFingerprint"]?.stringValue)
    }

    /// Inserts an inbound answer's attempt once; an attempt already held under its id, or one that would
    /// repeat a chat exchange's attempt, is left as it is.
    static func insertAttempt(_ attempt: MemoryAttempt, fingerprint: String?, connection: SQLiteConnection) throws {
        try connection.execute("""
            INSERT INTO memory_attempts (id, memory_item_id, session_id, exchange_id, attempt_type, prompt, learner_answer,
                feedback, score, schedule_rating, grade_state, grading_error, evidence_json, attempted_at, model_provider,
                model_id, model_metadata_json, parent_curriculum_fingerprint)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT DO NOTHING
        """, [
            .text(attempt.id), .text(attempt.memoryItemID), .text(attempt.sessionID), .text(attempt.exchangeID),
            .text(attempt.attemptType.rawValue), .text(attempt.prompt), .text(attempt.learnerAnswer), .text(attempt.feedback),
            .real(attempt.score), .text(attempt.scheduleRating?.rawValue), .text(attempt.gradeState.rawValue),
            .text(attempt.gradingError), .text(attempt.evidenceJSON), .real(attempt.attemptedAt.timeIntervalSinceReferenceDate),
            .text(attempt.modelProvider), .text(attempt.modelID), .text(attempt.modelMetadataJSON), .text(fingerprint),
        ])
    }
}
