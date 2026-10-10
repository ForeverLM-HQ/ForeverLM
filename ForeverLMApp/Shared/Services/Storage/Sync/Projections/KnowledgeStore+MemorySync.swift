import Foundation

// MARK: - The activation's memory derivations (docs/cloudkit-schema-design.md §13.3 step 3c)

extension KnowledgeStore {
    /// WP13's derivations, in order: the legacy Sittings of every attempt no Sitting holds yet, one Sitting
    /// per kept quiz score, the `legacy22` activity logs, each card's state, every draft deck's cards as
    /// their Cards (`deriveCardDrafts`, which reads the decks' bodies and so takes its own transaction per
    /// deck), and the items from before cards not gone through yet. Each is idempotent, bounded by the
    /// history it reads, and reads generation-1 truth only, so it reflects every generation-1 write made
    /// before the activation.
    static let memoryActivationDerivations: [ActivationDerivation] = [
        ActivationDerivation(id: "legacySittings") { store in try store.inDerivationTransaction { try $0.deriveLegacySittings() } },
        ActivationDerivation(id: "quizScoreSittings") { store in try store.inDerivationTransaction { try $0.deriveQuizScoreSittings() } },
        ActivationDerivation(id: "legacyActivityLogs") { store in try store.inDerivationTransaction { try $0.deriveLegacyActivityLogs() } },
        ActivationDerivation(id: "cardStates") { store in try store.inDerivationTransaction { try $0.deriveCardStates() } },
        ActivationDerivation(id: "cardDrafts") { store in try store.deriveCardDrafts() },
        ActivationDerivation(id: "legacyCardsToCheck") { store in try store.inDerivationTransaction { try $0.deriveLegacyCardsToCheck() } },
    ]

    /// At most this many answers in one Sitting part, and at most this much answer JSON, so the encoded
    /// part stays under the 128 KiB a part may hold with its stamps and fields (§3.5.23).
    static let sittingPartAnswerLimit = 200
    static let sittingPartAnswerBytes = 100 * 1_024

    /// Every attempt no Sitting holds yet as an answer of its migrated Sitting (§4.1, §10): grouped by its
    /// chat (`sit:legacy:` + sha256(`session:<id>`)), else by its local day (`day:<YYYY-MM-DD>`), so every
    /// Mac derives the same Sittings; a group past a part's limits continues in `<id>#2`, `#3`… An
    /// attempt recorded since an earlier run (a generation-1 release in between) joins its Sitting.
    func deriveLegacySittings() throws {
        var attempts: [(attempt: MemoryAttempt, fingerprint: String?)] = []
        try query("""
            SELECT a.id, a.memory_item_id, a.session_id, a.exchange_id, a.attempt_type, a.prompt, a.learner_answer,
                   a.feedback, a.score, a.schedule_rating, a.grade_state, a.grading_error, a.evidence_json,
                   a.attempted_at, a.model_provider, a.model_id, a.model_metadata_json, a.parent_curriculum_fingerprint
            FROM memory_attempts a
            WHERE NOT EXISTS (SELECT 1 FROM memory_sitting_answers s WHERE s.answer_id = a.id)
            ORDER BY a.attempted_at, a.id
        """, []) { row in
            guard let id = row.text(0), let item = row.text(1) else { return }
            attempts.append((MemoryAttempt(
                id: id, memoryItemID: item, sessionID: row.text(2), exchangeID: row.text(3),
                attemptType: row.text(4).flatMap(MemoryAttemptType.init(rawValue:)) ?? .review,
                prompt: row.text(5) ?? "", learnerAnswer: row.text(6) ?? "", feedback: row.text(7), score: row.real(8),
                scheduleRating: row.text(9).flatMap(MemoryScheduleRating.init(rawValue:)),
                gradeState: row.text(10).flatMap(MemoryGradeState.init(rawValue:)) ?? .pending, gradingError: row.text(11),
                evidenceJSON: row.text(12), attemptedAt: Date(timeIntervalSinceReferenceDate: row.real(13) ?? 0),
                modelProvider: row.text(14), modelID: row.text(15), modelMetadataJSON: row.text(16)
            ), row.text(17)))
        }
        var groups: [String: [(attempt: MemoryAttempt, fingerprint: String?)]] = [:]
        var order: [String] = []
        for entry in attempts {
            let key = entry.attempt.sessionID.map { "session:\($0)" } ?? "day:\(DayPlan.dateString(for: entry.attempt.attemptedAt))"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(entry)
        }
        for key in order.sorted() {
            let entries = groups[key] ?? []
            let first = SyncIdentity.sittingLegacyID(key)
            let chatID = entries.first?.attempt.sessionID
            for entry in entries {
                let answer = MemoryAnswerCodec.answer(for: entry.attempt, curriculumFingerprint: entry.fingerprint)
                try appendAnswer(
                    entry.attempt.id, answer: answer, at: entry.attempt.attemptedAt, toSittingStartingWith: first,
                    newSitting: (device: SyncIdentity.legacyDeviceID, kind: chatID == nil ? "cards" : "memoryReview", chatID: chatID)
                )
            }
        }
    }

    /// Each kept quiz score (`courseQuiz.score.<quizID>`, `lectureQuiz.score.<sourceID>`) as a Sitting of its
    /// own: `sit:legacy:` + sha256(`quiz:<courseQuiz|lectureQuiz>:<preference key>`), its result the score
    /// with the quiz's first pass (§3.5.23, §10). A score changed since an earlier run replaces its result.
    func deriveQuizScoreSittings() throws {
        var rows: [(key: String, xml: String)] = []
        try query("""
            SELECT key, value FROM user_preferences
            WHERE substr(key, 1, \(LectureQuizScore.courseQuizPreferenceKeyPrefix.count)) = ?
               OR substr(key, 1, \(LectureQuizScore.preferenceKeyPrefix.count)) = ?
            ORDER BY key
        """, [.text(LectureQuizScore.courseQuizPreferenceKeyPrefix), .text(LectureQuizScore.preferenceKeyPrefix)]) { row in
            if let key = row.text(0), let xml = row.text(1) { rows.append((key, xml)) }
        }
        for row in rows {
            guard let sitting = Self.quizScoreSitting(key: row.key, valuePlistXML: row.xml, deviceID: SyncIdentity.legacyDeviceID) else { continue }
            let id = SyncIdentity.sittingLegacyID("quiz:\(sitting.kind):\(row.key)")
            try upsertQuizSitting(sitting, id: id)
        }
    }

    /// A quiz score's preference row as a Sitting: its kind, scope and result. Nil for a row that is not
    /// a score.
    static func quizScoreSitting(key: String, valuePlistXML: String, deviceID: String) -> SittingRows.Sitting? {
        let kind: String
        let scope: SyncJSON
        if key.hasPrefix(LectureQuizScore.courseQuizPreferenceKeyPrefix) {
            kind = "courseQuiz"
            scope = ["quizID": .string(String(key.dropFirst(LectureQuizScore.courseQuizPreferenceKeyPrefix.count)))]
        } else if key.hasPrefix(LectureQuizScore.preferenceKeyPrefix) {
            kind = "lectureQuiz"
            scope = ["sourceID": .string(String(key.dropFirst(LectureQuizScore.preferenceKeyPrefix.count)))]
        } else {
            return nil
        }
        // A preference row is the plist `PreferenceStore.encodePlist` writes: the value under `v`.
        guard let value = PreferenceStore.decodePlist(valuePlistXML),
              let score = LectureQuizScore(preferenceValue: value)
        else { return nil }
        let takenAt = score.takenAt.timeIntervalSinceReferenceDate
        var result: [String: SyncJSON] = ["right": SyncJSON(score.right), "of": SyncJSON(score.total), "passed": .bool(score.passes)]
        if let passedAt = score.passedAt ?? (score.passes ? score.takenAt : nil) {
            result["passedAt"] = SyncJSON(SyncTime.milliseconds(passedAt))
        }
        return SittingRows.Sitting(
            id: "", deviceID: deviceID, kind: kind, scope: scope, startedAt: takenAt, endedAt: takenAt, chatID: nil, part: 1,
            result: .object(result), writeUp: nil, breakMinutes: nil, breakEndsAt: nil, abandonedAt: nil, answers: [:]
        )
    }

    private func upsertQuizSitting(_ sitting: SittingRows.Sitting, id: String) throws {
        try execute("""
            INSERT INTO memory_sittings (id, device_id, kind, scope_json, started_at, ended_at, part, result_json)
            VALUES (?, ?, ?, ?, ?, ?, 1, ?)
            ON CONFLICT(id) DO UPDATE SET
                scope_json = excluded.scope_json, started_at = excluded.started_at, ended_at = excluded.ended_at,
                result_json = excluded.result_json
        """, [
            .text(id), .text(sitting.deviceID), .text(sitting.kind), .text(SittingProjection.text(sitting.scope)),
            .real(sitting.startedAt), .real(sitting.endedAt), .text(SittingProjection.text(sitting.result)),
        ])
    }

    /// Adds an answer to the last part of the Sitting whose first part is `first`, or to a new part when that
    /// one is full (200 answers or 100 KiB of answers), creating the first part as `newSitting` describes. An
    /// answer already held is left as it is.
    @discardableResult
    func appendAnswer(
        _ answerID: String,
        answer: SyncJSON,
        at: Date,
        toSittingStartingWith first: String,
        newSitting: (device: String, kind: String, chatID: String?)
    ) throws -> String? {
        guard try scalarInteger("SELECT EXISTS(SELECT 1 FROM memory_sitting_answers WHERE answer_id = ?)", [.text(answerID)]) == 0,
              let subject = answer["subject"]?.stringValue
        else { return nil }
        let answerText = SittingProjection.text(answer) ?? "{}"
        var last: (id: String, part: Int64)?
        try query("""
            SELECT id, part FROM memory_sittings WHERE id = ? OR substr(id, 1, ?) = ? ORDER BY part DESC LIMIT 1
        """, [.text(first), .integer(Int64(first.count + 1)), .text(first + "#")]) { row in
            if let id = row.text(0) { last = (id, row.integer(1) ?? 1) }
        }
        var sittingID = first
        if let last {
            var count = 0
            var bytes = 0
            try query("SELECT COUNT(*), COALESCE(SUM(length(CAST(answer_json AS BLOB))), 0) FROM memory_sitting_answers WHERE sitting_id = ?", [.text(last.id)]) { row in
                count = Int(row.integer(0) ?? 0)
                bytes = Int(row.integer(1) ?? 0)
            }
            sittingID = last.id
            if count >= Self.sittingPartAnswerLimit || bytes + answerText.utf8.count > Self.sittingPartAnswerBytes {
                let part = last.part + 1
                sittingID = "\(first)#\(part)"
                try execute("""
                    INSERT INTO memory_sittings (id, device_id, kind, scope_json, started_at, chat_id, part)
                    SELECT ?, device_id, kind, scope_json, ?, chat_id, ? FROM memory_sittings WHERE id = ?
                    ON CONFLICT(id) DO NOTHING
                """, [.text(sittingID), .real(at.timeIntervalSinceReferenceDate), .integer(part), .text(last.id)])
            }
            try execute("""
                UPDATE memory_sittings SET ended_at = ?
                WHERE id = ? AND device_id = ? AND (ended_at IS NULL OR ended_at < ?)
            """, [.real(at.timeIntervalSinceReferenceDate), .text(sittingID), .text(SyncIdentity.legacyDeviceID), .real(at.timeIntervalSinceReferenceDate)])
        } else {
            let endedAt: Double? = newSitting.device == SyncIdentity.legacyDeviceID ? at.timeIntervalSinceReferenceDate : nil
            try execute("""
                INSERT INTO memory_sittings (id, device_id, kind, started_at, ended_at, chat_id, part) VALUES (?, ?, ?, ?, ?, ?, 1)
            """, [.text(first), .text(newSitting.device), .text(newSitting.kind), .real(at.timeIntervalSinceReferenceDate), .real(endedAt), .text(newSitting.chatID)])
        }
        try execute("""
            INSERT INTO memory_sitting_answers (answer_id, sitting_id, subject, at, counted, practice, answer_json)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, [
            .text(answerID), .text(sittingID), .text(subject), .real(at.timeIntervalSinceReferenceDate),
            .integer(answer["counted"]?.boolValue == false ? 0 : 1), .integer(answer["practice"]?.boolValue == true ? 1 : 0),
            .text(answerText),
        ])
        return sittingID
    }
}

// MARK: - Generation 2's memory recorders

extension KnowledgeStore {
    /// Whether this Mac records its memory history as generation 2 does: a generation-2 store once its
    /// activation is done. Before that, the activation's derivations take everything from generation-1
    /// truth, so recording here too would count it twice.
    func recordsMemoryForGeneration2() throws -> Bool {
        guard syncGeneration == .two else { return false }
        return try isActivatedForGeneration2()
    }

    /// An attempt this Mac just recorded, as an answer in this device's Sitting (generation 2 only, inside
    /// the caller's transaction): the chat's Sitting for a memory review, the day's `cards` Sitting
    /// otherwise. The Sitting is sent at most every 30 s (its projection's debounce, D44).
    func recordSittingAnswer(_ attempt: MemoryAttempt, curriculumFingerprint: String?) throws {
        guard try recordsMemoryForGeneration2() else { return }
        let device = try MemorySyncDevice.current(self) ?? ""
        let kind = attempt.sessionID == nil ? "cards" : "memoryReview"
        var first: String?
        if let chatID = attempt.sessionID {
            first = try scalarText("""
                SELECT id FROM memory_sittings WHERE device_id IN (?, '') AND kind = ? AND chat_id = ? AND part = 1
                ORDER BY started_at DESC LIMIT 1
            """, [.text(device), .text(kind), .text(chatID)])
        } else if let day = DayPlan.startOfDay(DayPlan.dateString(for: attempt.attemptedAt)),
                  let next = Calendar.current.date(byAdding: .day, value: 1, to: day) {
            first = try scalarText("""
                SELECT id FROM memory_sittings WHERE device_id IN (?, '') AND kind = ? AND chat_id IS NULL AND part = 1
                    AND started_at >= ? AND started_at < ?
                ORDER BY started_at DESC LIMIT 1
            """, [.text(device), .text(kind), .real(day.timeIntervalSinceReferenceDate), .real(next.timeIntervalSinceReferenceDate)])
        }
        try appendAnswer(
            attempt.id, answer: MemoryAnswerCodec.answer(for: attempt, curriculumFingerprint: curriculumFingerprint),
            at: attempt.attemptedAt, toSittingStartingWith: first ?? UUID().uuidString.lowercased(),
            newSitting: (device: device, kind: kind, chatID: attempt.sessionID)
        )
    }

    /// A memory preference row written on this Mac, mirrored into the memory records (generation 2 only,
    /// from `writePreference`): a kept quiz score becomes this device's Sitting for that sitting, and a
    /// deck's `cards.state.<deckID>` row its cards' states.
    func mirrorMemoryPreference(key: String, valuePlistXML: String) throws {
        guard key.hasPrefix(LectureQuizScore.courseQuizPreferenceKeyPrefix) || key.hasPrefix(LectureQuizScore.preferenceKeyPrefix)
                || key.hasPrefix(MemoryCardDeckState.preferenceKeyPrefix),
              try recordsMemoryForGeneration2()
        else { return }
        let device = try MemorySyncDevice.current(self) ?? ""
        if let sitting = Self.quizScoreSitting(key: key, valuePlistXML: valuePlistXML, deviceID: device) {
            // One Sitting per kept sitting: the same score written twice is one Sitting.
            let id = Self.uuidShaped(SyncIdentity.sha256Hex(Data("sitting:mac:\(key):\(SyncTime.milliseconds(cocoaSeconds: sitting.startedAt))".utf8)))
            try upsertQuizSitting(sitting, id: id)
        } else if let deckID = MemoryCardDeckState.deckID(fromPreferenceKey: key) {
            try mirrorCardDeckState(deckID: deckID, valuePlistXML: valuePlistXML)
        }
    }

    /// A UUID-shaped id from 32 hex characters, as the web names its Sittings (`sittingIDFor`).
    static func uuidShaped(_ hex: String) -> String {
        let digits = Array(hex.lowercased().prefix(32)).map(String.init)
        guard digits.count == 32 else { return UUID().uuidString.lowercased() }
        let variant = ["8", "9", "a", "b"][(Int(digits[16], radix: 16) ?? 0) % 4]
        return digits[0..<8].joined() + "-" + digits[8..<12].joined() + "-4" + digits[13..<16].joined() + "-"
            + variant + digits[17..<20].joined() + "-" + digits[20..<32].joined()
    }

    /// Gives the rows this Mac wrote before it knew its sync device id ('') that id, when its clock is made
    /// (WP16 calls this with the device id it creates the clock with). A day logged both ways is merged.
    func claimOwnMemoryRows(deviceID: String) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try execute("UPDATE memory_sittings SET device_id = ? WHERE device_id = ''", [.text(deviceID)])
            var days: [String] = []
            try query("SELECT day FROM device_activity_days WHERE device_id = ''", []) { row in
                if let day = row.text(0) { days.append(day) }
            }
            for day in days {
                guard let unclaimed = try loadDeviceActivityLog(day: day, deviceID: "") else { continue }
                var log = try loadDeviceActivityLog(day: day, deviceID: deviceID) ?? DeviceActivityLog(day: day)
                log.merge(unclaimed)
                try saveDeviceActivityLog(log, deviceID: deviceID)
                try execute("DELETE FROM device_activity_days WHERE day = ? AND device_id = ''", [.text(day)])
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}
