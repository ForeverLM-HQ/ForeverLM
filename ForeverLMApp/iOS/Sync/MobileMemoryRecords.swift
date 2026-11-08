import Foundation

// The phone's learning history under generation 2 (docs/cloudkit-schema-design.md §3.5.22–§3.5.24,
// D23, D24, D44; §14.2 WP20b). Generation 1 writes each graded answer as a `MemoryAttempt` record, the
// day's review minutes as this phone's `MemoryReviewActivity` row and a learning bout's break into the
// day's `DayPlan`, all in the old container. Once switched, the phone writes what the Mac's WP13 records
// hold: an answer joins this device's `Sitting` (one writer, each answer written once), a card kept here
// is a `Card` whose kept wording never changes, a quiz's score is a Sitting of its own, the review clock
// and the sources the learner spent time with are this device's `ActivityLog` of the day, and a bout's
// break end is `Sitting(kind bout).breakEndsAt`. The shapes are the Mac's (`MemoryAnswerCodec`,
// `CardProjection.kept`, `quizScoreSitting`) and the web's (`saveMemoryAttempt`, `recordActivity`).

enum MobileMemoryRecords {
    /// A Sitting part holds at most 200 answers, and its answers at most 100 KiB of JSON (the rest of the
    /// 128 KiB is stamps and fields, as the Mac counts); then a new part `<firstID>#<n>` starts (§3.5.23).
    static let partAnswers = 200
    static let partAnswerBytes = 100 * 1024
    /// A timed source activity is logged only after 30 s of engaged use, unless something was completed
    /// (§3.5.24).
    static let engagedMinimum: Double = 30

    /// A UUID-shaped id from 32 hex characters, as the web and the Mac name the Sittings they derive.
    static func uuidShaped(_ hex: String) -> String {
        let digits = Array(hex.lowercased().prefix(32)).map(String.init)
        guard digits.count == 32 else { return UUID().uuidString.lowercased() }
        let variant = ["8", "9", "a", "b"][(Int(digits[16], radix: 16) ?? 0) % 4]
        return digits[0..<8].joined() + "-" + digits[8..<12].joined() + "-4" + digits[13..<16].joined() + "-"
            + variant + digits[17..<20].joined() + "-" + digits[20..<32].joined()
    }

    static func hashed(_ text: String) -> String {
        uuidShaped(SyncIdentity.sha256Hex(Data(text.utf8)))
    }

    /// This device's Sitting for one chat, or for the day's card answers: the same id each time, so the
    /// one writer finds its Sitting again after a relaunch (the web's `sittingIDFor`, platform `ios`).
    static func sittingID(deviceID: String, scope: String) -> String {
        hashed("sitting:ios:\(deviceID):\(scope)")
    }

    /// One kept quiz score: the same score written twice is one Sitting, a retake another (the Mac's rule).
    static func quizSittingID(key: String, takenAt: Date) -> String {
        hashed("sitting:ios:\(key):\(SyncTime.milliseconds(takenAt))")
    }

    /// The Mac's `MemoryAnswerCodec.answer`: an attempt as the Answer it is in a Sitting.
    static func answer(for attempt: MemoryAttempt, curriculumFingerprint: String?) -> SyncJSON {
        var answer: [String: SyncJSON] = [
            "subject": .string("crd:" + attempt.memoryItemID),
            "at": SyncJSON(SyncTime.milliseconds(attempt.attemptedAt)),
            "prompt": .string(attempt.prompt),
            "response": .string(attempt.learnerAnswer),
            "counted": .bool(attempt.gradeState == .graded),
            "practice": .bool(false),
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
            answer["model"] = .object(["provider": attempt.modelProvider.map(SyncJSON.string) ?? .null, "id": .string(modelID)])
        }
        if let curriculumFingerprint { answer["curriculumFingerprint"] = .string(curriculumFingerprint) }
        if let exchangeID = attempt.exchangeID { answer["exchangeID"] = .string(exchangeID) }
        if attempt.attemptType != .review { answer["attemptType"] = .string(attempt.attemptType.rawValue) }
        if let error = attempt.gradingError { answer["gradingError"] = .string(error) }
        if let metadata = attempt.modelMetadataJSON { answer["modelMetadata"] = .string(metadata) }
        return .object(answer)
    }

    /// The attempt an answer about a card is, the inverse of `answer(for:curriculumFingerprint:)` and the
    /// Mac's `MemoryAnswerCodec.attempt`: nil for an answer about anything else, and for one that only
    /// practised (no grade state and not counted), which generation 1 never recorded. `sessionID` is the
    /// chat of the Sitting that holds it.
    static func attempt(answerID: String, answer: [String: SyncJSON], sessionID: String?) -> MemoryAttempt? {
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
        return MemoryAttempt(
            id: answerID, memoryItemID: cardID, sessionID: sessionID, exchangeID: answer["exchangeID"]?.stringValue,
            attemptType: answer["attemptType"]?.stringValue.flatMap(MemoryAttemptType.init(rawValue:)) ?? .review,
            prompt: answer["prompt"]?.stringValue ?? "", learnerAnswer: response, feedback: answer["feedback"]?.stringValue,
            score: score, scheduleRating: gradeState == .graded ? rating : nil, gradeState: gradeState,
            gradingError: answer["gradingError"]?.stringValue,
            evidenceJSON: answer["evidence"].flatMap { $0.isNull ? nil : String(decoding: $0.serialized(), as: UTF8.self) },
            attemptedAt: SyncTime.date(milliseconds: at), modelProvider: model?["provider"]?.stringValue,
            modelID: model?["id"]?.stringValue, modelMetadataJSON: answer["modelMetadata"]?.stringValue
        )
    }

    // MARK: Cards (§3.5.22)

    /// `Card.origin` for a Memory item kept here, as the Mac reads it from the rubric's card origin.
    static func origin(of item: MemoryItem) -> String {
        let rubric = (try? SyncJSON(parsing: Data(item.rubricJSON.utf8)))?["card"]?["origin"]?.stringValue
        switch rubric {
        case MemoryCardOrigin.walkthrough.rawValue?: return "walkthrough"
        case MemoryCardOrigin.courseQuiz.rawValue?: return "courseQuiz"
        case MemoryCardOrigin.assistant.rawValue?: return "assistant"
        case MemoryCardOrigin.manual.rawValue?: return "manual"
        case MemoryCardOrigin.drafted.rawValue?: return "guide"
        default: return item.kind == .concept ? "concept" : "chat"
        }
    }

    /// The kept wording of a Memory item, encoded the Mac's way every time (`CardProjection.kept`): the
    /// card's face as the front and the target as the back when the rubric holds a face, else the target
    /// as the front; the rubric as stored, which the fingerprint covers; the anchors in order.
    static func kept(from item: MemoryItem) -> SyncJSON {
        let face = (try? SyncJSON(parsing: Data(item.rubricJSON.utf8)))?["card"]?["front"]?.stringValue
        let anchors: [SyncJSON] = item.sources.sorted { ($0.sortIndex, $0.id) < ($1.sortIndex, $1.id) }.map { anchor in
            .object([
                "target": .string("src:" + anchor.sourceID), "excerpt": .string(anchor.excerpt), "textHash": .string(anchor.sourceSHA256),
                "id": .string(anchor.id), "sortIndex": SyncJSON(anchor.sortIndex),
                "locator": anchor.locatorJSON.flatMap { try? SyncJSON(parsing: Data($0.utf8)) } ?? .null,
            ])
        }
        return .object([
            "front": .string(face ?? item.target), "back": .string(face == nil ? "" : item.target), "rubric": .string(item.rubricJSON),
            "anchors": .array(anchors), "fingerprint": .string(MemoryTutorIdentity.immutableCurriculumFingerprint(item)),
            "at": SyncJSON(SyncTime.milliseconds(item.createdAt)),
        ])
    }

    /// A Card the phone keeps: status `kept`, its wording, when, and the item's other columns (`legacy`).
    static func keptCardPatch(_ item: MemoryItem) -> RecordPatch {
        var patch = RecordPatch(.card, id: item.id)
        let first = item.sources.min { ($0.sortIndex, $0.id) < ($1.sortIndex, $1.id) }?.sourceID
        patch.changes["status"] = .value(.string(item.status == .retired ? "retired" : "kept"))
        if let first { patch.changes["deckSourceID"] = .value(.string(first)) }
        patch.changes["origin"] = .value(.string(origin(of: item)))
        patch.changes["kept"] = .value(kept(from: item))
        patch.changes["keptAt"] = .value(SyncJSON(SyncTime.milliseconds(item.createdAt)))
        patch.changes["madeBy"] = .value(.object(["at": SyncJSON(SyncTime.milliseconds(item.createdAt))]))
        patch.changes["legacy"] = .value(.object([
            "kind": .string(item.kind.rawValue), "target": .string(item.target),
            "learnerContext": item.learnerContext.map(SyncJSON.string) ?? .null, "goalID": item.goalID.map(SyncJSON.string) ?? .null,
            "ideaID": item.ideaID.map(SyncJSON.string) ?? .null,
        ]))
        return patch
    }

    /// A Card kept on any device as the phone's Memory item (the Mac's inbound reading): the back when it
    /// has one, else the front, else `legacy.target`; the other columns from `legacy`; the anchors in
    /// order. Nil for a Card that was never kept.
    static func item(fromCard fields: [String: SyncJSON], id: String) -> MemoryItem? {
        guard let kept = fields["kept"]?.objectValue else { return nil }
        let legacy = fields["legacy"]?.objectValue ?? [:]
        func clean(_ value: SyncJSON?) -> String? {
            guard let text = value?.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return text
        }
        let front = clean(kept["front"]) ?? ""
        let target = clean(kept["back"]) ?? clean(kept["front"]) ?? clean(legacy["target"]) ?? ""
        let rubric = clean(kept["rubric"]) ?? String(decoding: SyncJSON.object([
            "card": .object(["cardID": .string(id), "front": .string(front), "origin": .string(fields["origin"]?.stringValue ?? "manual")]),
            "criteria": .array([]),
        ]).serialized(), as: UTF8.self)
        let keptAt = (fields["keptAt"]?.int64Value ?? kept["at"]?.int64Value).map(SyncTime.date(milliseconds:)) ?? Date(timeIntervalSince1970: 0)
        let sources: [MemoryItemSource] = (kept["anchors"]?.arrayValue ?? []).enumerated().compactMap { index, anchor in
            guard let object = anchor.objectValue else { return nil }
            let target = object["target"]?.stringValue ?? ""
            let sourceID = target.hasPrefix("src:") ? String(target.dropFirst(4)).components(separatedBy: "#")[0] : target
            return MemoryItemSource(
                id: object["id"]?.stringValue ?? "\(id)#anchor-\(index)", memoryItemID: id, sourceID: sourceID,
                locatorJSON: object["locator"].flatMap { $0 == .null ? nil : String(decoding: $0.serialized(), as: UTF8.self) },
                excerpt: object["excerpt"]?.stringValue ?? "", sourceSHA256: object["textHash"]?.stringValue ?? "",
                sortIndex: object["sortIndex"]?.intValue ?? index
            )
        }
        return MemoryItem(
            id: id, kind: legacy["kind"]?.stringValue.flatMap(MemoryItemKind.init(rawValue:)) ?? .concept, target: target,
            rubricJSON: rubric, learnerContext: clean(legacy["learnerContext"]), goalID: clean(legacy["goalID"]),
            status: fields["status"]?.stringValue == "retired" ? .retired : .active, sources: sources,
            createdAt: keptAt, updatedAt: keptAt, ideaID: clean(legacy["ideaID"])
        )
    }

    /// The wire kind of a source activity (§3.5.24).
    static func wireKind(_ kind: SourceActivityKind) -> String {
        switch kind {
        case .reading: return "read"
        case .listening: return "listen"
        case .watching: return "watch"
        case .chat: return "chat"
        case .review: return "review"
        }
    }

    static func isTimed(_ kind: SourceActivityKind) -> Bool {
        kind == .reading || kind == .listening || kind == .watching
    }
}

/// What writing an answer into the device's Sitting did.
enum MobileAnswerOutcome: Equatable, Sendable {
    case recorded
    /// This answer is in the Sitting already (a retry, or the same answer sent twice).
    case alreadyRecorded
    /// A different answer is held under this id.
    case conflict
}

/// What keeping a card did: kept here, or another device's kept wording was found first.
enum MobileKeepOutcome: Equatable, Sendable {
    case kept
    case keptElsewhere(MemoryItem)
}

extension MobileWrite {
    // MARK: - Sittings (§3.5.23)

    /// Writes `attempt` once into this device's Sitting: the chat's (`memoryReview`) when it names a chat
    /// session, else the day's card answers (`cards`). A held answer under the same id is `alreadyRecorded`
    /// when it is the same answer (or `anyHeldCounts`, the card review's rule), else `conflict`.
    mutating func recordAnswer(_ attempt: MemoryAttempt, curriculumFingerprint: String?, anyHeldCounts: Bool = false) throws -> MobileAnswerOutcome {
        let answer = MobileMemoryRecords.answer(for: attempt, curriculumFingerprint: curriculumFingerprint)
        let chatID = attempt.sessionID.flatMap { $0.isEmpty ? nil : $0 }
        let scope = chatID ?? "day:\(MemoryReviewGoal.dayKey(for: attempt.attemptedAt))"
        let firstID = MobileMemoryRecords.sittingID(deviceID: deviceID, scope: scope)
        let parts = try sittingParts(firstID)
        // Each part decoded once: the answer may be in any of them, and the first and last are read below.
        var envelopes: [SyncEnvelope?] = []
        for (id, _) in parts {
            let envelope = try held(.sitting, id, in: Self.libraryKey)
            envelopes.append(envelope)
            guard let held = envelope?.fields["answers"]?[attempt.id], held != .null else { continue }
            return anyHeldCounts || held == answer ? .alreadyRecorded : .conflict
        }
        let last = envelopes.last ?? nil
        var target = parts.last
        if let last, let lastPart = parts.last {
            let answers = last.fields["answers"]?.objectValue ?? [:]
            let bytes = SyncJSON.object(answers).serialized().count + answer.serialized().count
            if answers.count >= MobileMemoryRecords.partAnswers || bytes > MobileMemoryRecords.partAnswerBytes {
                target = (id: "\(firstID)#\(lastPart.part + 1)", part: lastPart.part + 1)
            }
        }
        let first = envelopes.first ?? nil
        var patch = RecordPatch(.sitting, id: target?.id ?? firstID)
        if target == nil || target?.id != parts.last?.id {
            patch.changes["deviceID"] = .value(.string(deviceID))
            patch.changes["kind"] = .value(.string(first?.fields["kind"]?.stringValue ?? (chatID == nil ? "cards" : "memoryReview")))
            patch.changes["startedAt"] = .value(first?.fields["startedAt"] ?? SyncJSON(SyncTime.milliseconds(attempt.attemptedAt)))
            patch.changes["part"] = .value(SyncJSON(target?.part ?? 1))
            if let chatID { patch.changes["chatID"] = .value(.string(chatID)) }
        }
        patch.changes["answers"] = .elements([attempt.id: answer])
        try write(patch, in: Self.libraryKey)
        return .recorded
    }

    /// The parts of the Sitting that starts with `firstID`, in order.
    func sittingParts(_ firstID: String) throws -> [(id: String, part: Int)] {
        try rows("""
            SELECT id, COALESCE(part, 1) FROM m_sittings WHERE zone_key = ? AND (id = ? OR substr(id, 1, ?) = ?) ORDER BY 2, id
        """, [.text(Self.libraryKey), .text(firstID), .integer(Int64(firstID.count + 1)), .text(firstID + "#")]).map { ($0[0], Int($0[1]) ?? 1) }
    }

    /// The answer a Sitting of this device holds under `answerID`, in whichever part.
    func heldAnswer(_ answerID: String, sessionID: String?, at date: Date) throws -> SyncJSON? {
        let scope = sessionID.flatMap { $0.isEmpty ? nil : $0 } ?? "day:\(MemoryReviewGoal.dayKey(for: date))"
        for (id, _) in try sittingParts(MobileMemoryRecords.sittingID(deviceID: deviceID, scope: scope)) {
            if let answer = try held(.sitting, id, in: Self.libraryKey)?.fields["answers"]?[answerID], answer != .null { return answer }
        }
        return nil
    }

    /// Marks this device's chat Sitting ended (L), when the chat is.
    mutating func endSitting(chatID: String, at date: Date) throws {
        let firstID = MobileMemoryRecords.sittingID(deviceID: deviceID, scope: chatID)
        for (id, _) in try sittingParts(firstID) {
            var patch = RecordPatch(.sitting, id: id)
            patch.changes["endedAt"] = .value(SyncJSON(SyncTime.milliseconds(date)))
            try write(patch, in: Self.libraryKey)
        }
    }

    // MARK: - Cards (§3.5.22, D24)

    /// A kept Card the phone holds, as the Memory item it is; nil when none was kept under `id`.
    func keptItem(_ id: String) throws -> MemoryItem? {
        guard let card = try held(.card, id, in: Self.libraryKey) else { return nil }
        return MobileMemoryRecords.item(fromCard: card.fields, id: id)
    }

    /// Keeps `item` as a Card. A card already kept under its id keeps its wording (S, the first Keep
    /// stands): when that wording is another curriculum, it comes back as `keptElsewhere`.
    mutating func keepCard(_ item: MemoryItem) throws -> MobileKeepOutcome {
        if let held = try keptItem(item.id) {
            return MemoryTutorIdentity.hasSameImmutableCurriculum(held, item) ? .kept : .keptElsewhere(held)
        }
        try write(MobileMemoryRecords.keptCardPatch(item), in: Self.libraryKey)
        return .kept
    }

    // MARK: - Quiz scores (§3.5.23, §10 `courseQuiz.score.*`, `lectureQuiz.score.*`)

    /// The latest sitting of the quiz a score key names, with the quiz's first pass (whichever sitting made
    /// it); nil before the quiz was taken.
    func quizScore(_ key: String) throws -> LectureQuizScore? {
        let column: String
        let id: String
        let kind: String
        if key.hasPrefix(LectureQuizScore.courseQuizPreferenceKeyPrefix) {
            (column, kind, id) = ("quiz_id", "courseQuiz", String(key.dropFirst(LectureQuizScore.courseQuizPreferenceKeyPrefix.count)))
        } else if key.hasPrefix(LectureQuizScore.preferenceKeyPrefix) {
            (column, kind, id) = ("scope_source_id", "lectureQuiz", String(key.dropFirst(LectureQuizScore.preferenceKeyPrefix.count)))
        } else {
            return nil
        }
        var latest: (at: Int64, id: String, right: Int, total: Int)?
        var firstPass: Int64?
        for row in try rows("""
            SELECT id, started_at, result_json FROM m_sittings WHERE zone_key = ? AND kind = ? AND \(column) = ?
        """, [.text(Self.libraryKey), .text(kind), .text(id)]) {
            guard let result = try? SyncJSON(parsing: Data(row[2].utf8)), let right = result["right"]?.intValue,
                  let total = result["of"]?.intValue, total > 0, right >= 0, right <= total else { continue }
            let at = Int64(row[1]) ?? 0
            if let passedAt = result["passedAt"]?.int64Value { firstPass = min(firstPass ?? passedAt, passedAt) }
            if latest.map({ ($0.at, $0.id) < (at, row[0]) }) ?? true { latest = (at, row[0], right, total) }
        }
        guard let latest else { return nil }
        return LectureQuizScore(right: latest.right, total: latest.total, takenAt: SyncTime.date(milliseconds: latest.at),
                                passedAt: firstPass.map(SyncTime.date(milliseconds:)))
    }

    /// A kept quiz score as this device's Sitting of it (the Mac's `quizScoreSitting`): its scope, the
    /// sitting's time as its start and end, and the result with the quiz's first pass.
    mutating func recordQuizScore(_ score: LectureQuizScore, key: String) throws {
        let kind: String
        let scope: SyncJSON
        if key.hasPrefix(LectureQuizScore.courseQuizPreferenceKeyPrefix) {
            kind = "courseQuiz"
            scope = .object(["quizID": .string(String(key.dropFirst(LectureQuizScore.courseQuizPreferenceKeyPrefix.count)))])
        } else if key.hasPrefix(LectureQuizScore.preferenceKeyPrefix) {
            kind = "lectureQuiz"
            scope = .object(["sourceID": .string(String(key.dropFirst(LectureQuizScore.preferenceKeyPrefix.count)))])
        } else {
            throw MobileRecordWriterError.refused("\"\(key)\" is not a quiz score.")
        }
        let takenAt = SyncJSON(SyncTime.milliseconds(score.takenAt))
        var result: [String: SyncJSON] = ["right": SyncJSON(score.right), "of": SyncJSON(score.total), "passed": .bool(score.passes)]
        if let passedAt = score.passedAt ?? (score.passes ? score.takenAt : nil) { result["passedAt"] = SyncJSON(SyncTime.milliseconds(passedAt)) }
        var patch = RecordPatch(.sitting, id: MobileMemoryRecords.quizSittingID(key: key, takenAt: score.takenAt))
        patch.changes["deviceID"] = .value(.string(deviceID))
        patch.changes["kind"] = .value(.string(kind))
        patch.changes["scope"] = .value(scope)
        patch.changes["startedAt"] = .value(takenAt)
        patch.changes["endedAt"] = .value(takenAt)
        patch.changes["part"] = .value(SyncJSON(1))
        patch.changes["result"] = .value(.object(result))
        try write(patch, in: Self.libraryKey)
    }

    // MARK: - The device's ActivityLog (§3.5.24)

    /// This device's review clock of `day`: the seconds it counted, the goal they were counted against.
    func reviewSeconds(day: String) throws -> Double? {
        try held(.activityLog, SyncIdentity.activityLogID(day: day, deviceID: deviceID), in: Self.libraryKey)?.fields["review"]?["seconds"]?.numberValue
    }

    /// Writes this device's review clock of `day` (the goal clock that was `MemoryReviewActivity`): never
    /// lower than what the log holds, since this device is its only writer.
    mutating func recordReviewSeconds(day: String, seconds: Double, goalSeconds: Double, at date: Date) throws {
        let held = try reviewSeconds(day: day) ?? 0
        guard seconds > held else { return }
        var patch = activityLogPatch(day: day)
        patch.changes["review"] = .value(.object([
            "seconds": .number(seconds.rounded()), "goalSeconds": .number(goalSeconds), "at": SyncJSON(SyncTime.milliseconds(date)),
        ]))
        try write(patch, in: Self.libraryKey)
    }

    /// The source's element of this device's log of `day`, merged with what it held (the web's
    /// `recordActivity`): kinds and completed kinds unioned, the deepest fraction, engaged seconds added,
    /// the first and last times widened.
    mutating func recordSourceActivity(sourceID: String, day: String, kind: String, at date: Date, completed: Bool,
                                       fraction: Double?, engagedSeconds: Double, notebookIDs: [String] = []) throws {
        let at = SyncTime.milliseconds(date)
        let previous = try heldSourceActivity(sourceID: sourceID, day: day) ?? [:]
        func list(_ key: String) -> [String] { previous[key]?.arrayValue?.compactMap(\.stringValue) ?? [] }
        let element: [String: SyncJSON] = [
            "kinds": .array(Set(list("kinds") + [kind]).sorted().map(SyncJSON.string)),
            "completedKinds": .array(Set(list("completedKinds") + (completed ? [kind] : [])).sorted().map(SyncJSON.string)),
            "maxFraction": .number(max(previous["maxFraction"]?.numberValue ?? 0, fraction.map { min(max($0, 0), 1) } ?? 0)),
            "engagedSeconds": .number(((previous["engagedSeconds"]?.numberValue ?? 0) + max(engagedSeconds, 0)).rounded()),
            "notebookIDs": .array(Set(list("notebookIDs") + notebookIDs).sorted().map(SyncJSON.string)),
            "firstAt": SyncJSON(min(previous["firstAt"]?.int64Value ?? at, at)),
            "lastAt": SyncJSON(max(previous["lastAt"]?.int64Value ?? at, at)),
        ]
        guard SyncJSON.object(element) != SyncJSON.object(previous) else { return }
        var patch = activityLogPatch(day: day)
        patch.changes["sources"] = .elements([sourceID: .object(element)])
        try write(patch, in: Self.libraryKey)
    }

    func heldSourceActivity(sourceID: String, day: String) throws -> [String: SyncJSON]? {
        try held(.activityLog, SyncIdentity.activityLogID(day: day, deviceID: deviceID), in: Self.libraryKey)?.fields["sources"]?[sourceID]?.objectValue
    }

    private func activityLogPatch(day: String) -> RecordPatch {
        var patch = RecordPatch(.activityLog, id: SyncIdentity.activityLogID(day: day, deviceID: deviceID))
        patch.changes["day"] = .value(.string(day))
        patch.changes["deviceID"] = .value(.string(deviceID))
        return patch
    }

    // MARK: - Learning bouts (§3.5.23 kind `bout`)

    /// The bouts started since `since`, read from their Sittings as the Mac writes them (WP13): the scope
    /// carries the title, plan, notebook, sources and block; `breakEndsAt` is when the break ends.
    /// `breakEndedAt` stays each device's own (the Mac keeps it local), so it comes from `endedBreaks`, the
    /// breaks this phone ended.
    func bouts(since: Date, endedBreaks: [String: Date]) throws -> [LearningBout] {
        var bouts: [LearningBout] = []
        for row in try rows("SELECT id FROM m_sittings WHERE zone_key = ? AND kind = 'bout' AND started_at >= ? ORDER BY started_at, id",
                            [.text(Self.libraryKey), .integer(SyncTime.milliseconds(since))]) {
            guard let fields = try held(.sitting, row[0], in: Self.libraryKey)?.fields,
                  let startedAt = fields["startedAt"]?.int64Value.map(SyncTime.date(milliseconds:)) else { continue }
            let scope = fields["scope"]?.objectValue ?? [:]
            let writeUp = fields["writeUp"]?.objectValue
            let breakMinutes = fields["breakMinutes"]?.intValue ?? 0
            let breakEndsAt = fields["breakEndsAt"]?.int64Value.map(SyncTime.date(milliseconds:))
            func date(_ value: SyncJSON?) -> Date? { value?.int64Value.map(SyncTime.date(milliseconds:)) }
            bouts.append(LearningBout(
                id: row[0], dayPlanID: PlanDate.string(for: startedAt), blockID: scope["blockID"]?.stringValue,
                title: scope["title"]?.stringValue ?? "", notebookID: scope["notebookID"]?.stringValue,
                sourceIDs: scope["sourceIDs"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                plannedMinutes: scope["plannedMinutes"]?.intValue ?? LearningBout.defaultMinutes, startedAt: startedAt,
                endedAt: date(fields["endedAt"]), learned: writeUp?["learned"]?.stringValue, unclear: writeUp?["unclear"]?.stringValue,
                writtenAt: date(writeUp?["writtenAt"]), breakMinutes: breakMinutes,
                breakStartedAt: breakEndsAt.map { $0.addingTimeInterval(-Double(breakMinutes) * 60) },
                breakEndedAt: endedBreaks[row[0]], abandonedAt: date(fields["abandonedAt"]), createdAt: startedAt,
                updatedAt: date(fields["editedAt"]) ?? startedAt
            ))
        }
        return bouts
    }

    /// Ends a bout's break now: `breakEndsAt` (L) moves to `date`, which the Mac reads as a break that
    /// started its length earlier and is over. A break whose end has passed already keeps it.
    mutating func endBreak(boutID: String, at date: Date) throws {
        guard let bout = try held(.sitting, boutID, in: Self.libraryKey) else {
            throw MobileRecordWriterError.refused("This learning bout is not on this iPhone yet.")
        }
        if let endsAt = bout.fields["breakEndsAt"]?.int64Value, endsAt <= SyncTime.milliseconds(date) { return }
        var patch = RecordPatch(.sitting, id: boutID)
        patch.changes["breakEndsAt"] = .value(SyncJSON(SyncTime.milliseconds(date)))
        try write(patch, in: Self.libraryKey)
    }
}

extension MobileRecordWriter {
    /// Makes what waits on the Sittings' 30 s and the ActivityLog's 5-minute debounce due now: at a sitting's
    /// end and when the app leaves the foreground (D44). The session sends it in a round soon after, unless
    /// the caller sends it itself (`sendsSoon` false: the app leaving the foreground, which runs the round
    /// inside its background task). Returns whether anything was waiting.
    @discardableResult
    func flushLearningHistory(sendsSoon: Bool = true) async throws -> Bool {
        let flushed = try await replica.read { replica in
            try replica.connection.execute("UPDATE ck_patches SET dirty_at = 0 WHERE record_type IN (?, ?)",
                                           [.text(SyncRecordType.sitting.rawValue), .text(SyncRecordType.activityLog.rawValue)])
            return try replica.connection.scalarInteger("SELECT changes()") ?? 0
        }
        if flushed > 0, sendsSoon { notifyWritten(due: 0) }
        return flushed > 0
    }
}

/// The phone's source activity under generation 2 (§3.5.24): timed use (reading, listening, watching)
/// is held here until the source has 30 s of engaged use on the day, then logged and added to from then
/// on; a chat, a review or a completion is logged at once. Opening a source logs nothing (P9).
actor MobileActivityLogRecorder {
    static let shared = MobileActivityLogRecorder()

    private struct Key: Hashable {
        let day: String
        let sourceID: String
        let kind: String
    }

    private struct Held {
        var seconds: Double = 0
        var fraction: Double?
        var firstAt: Date
    }

    private var held: [Key: Held] = [:]

    /// Whether the activity was logged (false while timed use is still under 30 s on the day).
    @discardableResult
    func record(sourceID: String, kind: SourceActivityKind, at date: Date, fraction: Double?, engagedSeconds: Double, completed: Bool,
                writer: MobileRecordWriter) async throws -> Bool {
        let day = MemoryReviewGoal.dayKey(for: date)
        let key = Key(day: day, sourceID: sourceID, kind: MobileMemoryRecords.wireKind(kind))
        var pending = held[key] ?? Held(firstAt: date)
        pending.seconds += max(engagedSeconds, 0)
        if let fraction { pending.fraction = max(pending.fraction ?? 0, fraction) }
        let logged = try await writer.read { try $0.heldSourceActivity(sourceID: sourceID, day: day)?["kinds"]?.arrayValue?.contains(.string(key.kind)) == true }
        guard logged || completed || !MobileMemoryRecords.isTimed(kind) || pending.seconds >= MobileMemoryRecords.engagedMinimum else {
            held[key] = pending
            return false
        }
        held[key] = nil
        let first = pending.firstAt
        let seconds = pending.seconds
        let deepest = pending.fraction
        do {
            try await writer.transaction { write in
                try write.recordSourceActivity(sourceID: sourceID, day: day, kind: key.kind, at: first, completed: false,
                                               fraction: deepest, engagedSeconds: seconds)
                if date != first || completed {
                    try write.recordSourceActivity(sourceID: sourceID, day: day, kind: key.kind, at: date, completed: completed,
                                                   fraction: nil, engagedSeconds: 0)
                }
            }
        } catch {
            // What was counted waits for the next write.
            held[key, default: Held(firstAt: first)].seconds += seconds
            throw error
        }
        return true
    }
}

// MARK: - The day's memory review (§3.5.13 kind `memory`, §3.5.14) and a source's ideas (§3.5.30 `ideas`)

/// The day's memory review as the phone holds it: the Chat and its Exchanges in seq order.
struct MobileMemoryReviewHeld {
    let chat: SyncEnvelope
    let exchanges: [SyncEnvelope]
}

extension MobileWrite {
    static let memoryReviewNote = "Recorded from today's memory review on iOS."

    /// The day's review chat with its exchanges; nil when no device has prepared it.
    func memoryReview(_ sessionID: String) throws -> MobileMemoryReviewHeld? {
        guard let chat = try held(.chat, sessionID, in: Self.libraryKey) else { return nil }
        let exchanges = try rows("SELECT id FROM m_exchanges WHERE zone_key = ? AND chat_id = ?", [.text(Self.libraryKey), .text(sessionID)])
            .compactMap { try held(.exchange, $0[0], in: Self.libraryKey) }
            .sorted { ($0.fields["seq"]?.int64Value ?? 0, $0.id) < ($1.fields["seq"]?.int64Value ?? 0, $1.id) }
        return MobileMemoryReviewHeld(chat: chat, exchanges: exchanges)
    }

    /// The day's review chat, its briefing (uploaded first) and the tutor's opening question.
    mutating func createMemoryReview(_ draft: MobileMemoryReviewStore.Draft, briefing: FileRef?) throws {
        let opening = MobileChatRecord.Exchange(id: MobileMemoryReviewStore.exchangeID(sessionID: draft.sessionID, sequence: 1), seq: 1,
                                                question: draft.openingQuestion, userAnswer: nil, evaluation: nil, score: nil, answeredAt: nil,
                                                sourceRefs: [], knowledgeNote: nil)
        try recordChat(MobileChatRecord(id: draft.sessionID, kind: .memory, notebookID: nil, title: draft.topic, startedAt: draft.startedAt,
                                        endedAt: nil, summary: nil, overallScore: nil, sourceIDs: draft.sourceIDs, modelProvider: draft.modelProvider,
                                        modelID: draft.modelID, exchanges: [opening]))
        if let briefing {
            var patch = RecordPatch(.chat, id: draft.sessionID)
            patch.changes["briefing"] = .value(briefing.value)
            try write(patch, in: Self.libraryKey, edited: false)
        }
    }

    /// The tutor's opening question on a review that has none yet.
    mutating func recordMemoryReviewOpening(sessionID: String, question: String) throws {
        guard let review = try memoryReview(sessionID) else { throw MobileRecordWriterError.chatGone }
        guard review.exchanges.isEmpty else { return }
        try writeMemoryReviewExchange(sessionID: sessionID, seq: 1, fields: [
            "question": .string(question), "createdAt": SyncJSON(milliseconds),
        ])
    }

    /// One turn, as generation 1 records it on the review's record: the learner's answer to the open
    /// question and the tutor's reply on the unanswered exchange, else on a new one whose question is the
    /// last reply; the grade when there was one; the steer given before answering on the graded exchange
    /// it steered. An answered exchange is never rewritten (its fields are S).
    mutating func recordMemoryReviewTurn(sessionID: String, answer: String, reply: String, grade: MemoryContourGrade?,
                                         steerBefore: MemoryReviewSteer?, answeredAt: Date) throws {
        guard let review = try memoryReview(sessionID) else { throw MobileRecordWriterError.chatGone }
        if let steerBefore, let last = review.exchanges.last, var grading = last.fields["grading"]?.objectValue,
           grading["ideaCoverage"] != nil, grading["steer"] == nil {
            grading["steer"] = .string(steerBefore.rawValue)
            var patch = RecordPatch(.exchange, id: last.id)
            patch.changes["grading"] = .value(.object(grading))
            try write(patch, in: Self.libraryKey)
        }
        let chatSources = members(review.chat.fields["contextSourceIDs"])
        var fields: [String: SyncJSON] = [
            "userAnswer": .string(answer), "evaluation": .string(reply), "answeredAt": SyncJSON(SyncTime.milliseconds(answeredAt)),
            "sourceRefs": .array((grade.map { [$0.sourceID] } ?? chatSources).map(SyncJSON.string)), "knowledgeNote": .string(Self.memoryReviewNote),
        ]
        if let grade {
            fields["score"] = .number(grade.score)
            fields["grading"] = .object([
                "ideaCoverage": .array(grade.coverage.map { .object(["ideaID": .string($0.ideaID), "status": .string($0.status.rawValue)]) }),
                "questionVerdict": .string(grade.verdict.rawValue), "operation": .string(grade.operation.rawValue),
            ])
        }
        let seq: Int
        if let last = review.exchanges.last, (last.fields["userAnswer"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            seq = last.fields["seq"]?.intValue ?? review.exchanges.count
        } else {
            guard let previous = review.exchanges.last,
                  let question = previous.fields["evaluation"]?.stringValue ?? previous.fields["question"]?.stringValue else {
                throw MobileMemoryReviewStoreError.noOpenQuestion
            }
            seq = (review.exchanges.compactMap { $0.fields["seq"]?.intValue }.max() ?? 0) + 1
            fields["question"] = .string(question)
            fields["createdAt"] = SyncJSON(SyncTime.milliseconds(answeredAt))
        }
        try writeMemoryReviewExchange(sessionID: sessionID, seq: seq, fields: fields)
        var chat = RecordPatch(.chat, id: sessionID)
        chat.changes["editedAt"] = .value(SyncJSON(SyncTime.milliseconds(answeredAt)))
        try write(chat, in: Self.libraryKey, edited: false)
    }

    private mutating func writeMemoryReviewExchange(sessionID: String, seq: Int, fields: [String: SyncJSON]) throws {
        var patch = RecordPatch(.exchange, id: MobileMemoryReviewStore.exchangeID(sessionID: sessionID, sequence: seq))
        patch.changes["chatID"] = .value(.string(sessionID))
        patch.changes["seq"] = .value(SyncJSON(seq))
        for (field, value) in fields { patch.changes[field] = .value(value) }
        try write(patch, in: Self.libraryKey)
    }

    // MARK: A source's ideas

    /// The `ideas` satellite a source of the learner's `Catalog` names, if any.
    func ideasFile(sourceID: String) throws -> FileRef? {
        try held(.source, sourceID, in: Self.catalogKey)?.fields["derived"]?["ideas"].flatMap(FileRef.init(json:))
    }

    /// Points the source at the ideas the phone extracted (uploaded first), with the provisional stamp, so
    /// a Mac maker's output beats it; only when the source has none and is the learner's own (§10).
    mutating func pointAtIdeas(sourceID: String, file: FileRef) throws {
        guard try held(.source, sourceID, in: Self.catalogKey) != nil, try ideasFile(sourceID: sourceID) == nil else { return }
        var patch = RecordPatch(.source, id: sourceID)
        patch.changes["derived"] = .elements(["ideas": file.value])
        try write(patch, in: Self.catalogKey, provisional: ["derived"], edited: false)
    }
}

enum MobileSourceIdeasSatellite {
    static let role = "ideas"

    /// A source's ideas as the `ideas` satellite holds them: `{"ideas": [<SourceIdea>]}`, each idea as the
    /// Mac's `SourceIdea` payload encodes it, its id the stable `ideaKey`.
    static func encode(_ ideas: [SourceIdea]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let items = try ideas.sorted { ($0.sortIndex, $0.id) < ($1.sortIndex, $1.id) }.map { try JSONSerialization.jsonObject(with: encoder.encode($0)) }
        return try JSONSerialization.data(withJSONObject: ["ideas": items], options: [.sortedKeys])
    }

    static func decode(_ data: Data) -> [SourceIdea] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let items = object["ideas"] as? [Any] else { return [] }
        return items.compactMap { item in
            guard let data = try? JSONSerialization.data(withJSONObject: item) else { return nil }
            return try? JSONDecoder().decode(SourceIdea.self, from: data)
        }
    }
}
