import Foundation

// MARK: - The member's reading state of one work (docs/cloudkit-schema-design.md §3.5.18, §8b)

/// One `reading_states` row: where the learner is in a source, how far they got, its read, completed
/// and consumed marks, its review depth, the narration's resume point, and what the record carries
/// that no other table holds. Keyed by the source's wire id with no foreign key (D18), so the personal
/// copy and a team copy share it and it outlives the source.
struct ReadingStateRow: Equatable, Sendable {
    var wireID: String
    /// The record's Locator (§3.3), with the Mac reader's own encoding under `mac`.
    var locator: SyncJSON?
    /// The PDF page index the Mac's reader keeps.
    var position: Int64?
    var readAt: Double?
    var reviewDepth: String?
    var furthestEpoch: Int64?
    var furthest: Double?
    var completedAt: Double?
    var consumedAt: Double?
    var lastReadAt: Double?
    var listen: SyncJSON?
    var media: SyncJSON?
    var watchedSeconds: Double?
    var lastContext: SyncJSON?
    /// Walk variants other than `main` (a course's walk), as the record holds them.
    var walkVariants: [String: SyncJSON] = [:]
    /// The discussed idea keys of a source with no Understanding row on this Mac.
    var discussed: [String]?
    /// The Understanding document's FileRef, and the file it was laid out from.
    var understanding: SyncJSON?
    var understandingPath: String?

    init(wireID: String) {
        self.wireID = wireID
    }

    static let columns = [
        "locator_json", "position", "read_at", "review_depth", "furthest_epoch", "furthest", "completed_at", "consumed_at",
        "last_read_at", "listen_json", "media_json", "watched_seconds", "last_context_json", "walk_variants_json",
        "discussed_json", "understanding_json", "understanding_path",
    ]

    /// Whether the row says nothing: the record a writer would create for it is not made (§3.5.18:
    /// created only when a position or a flag first changes).
    var isEmpty: Bool { self == ReadingStateRow(wireID: wireID) }

    static func load(_ wireID: String, connection: SQLiteConnection) throws -> ReadingStateRow? {
        var row: ReadingStateRow?
        try connection.query(
            "SELECT \(columns.joined(separator: ", ")) FROM reading_states WHERE wire_id = ?", [.text(wireID)]
        ) { values in
            var loaded = ReadingStateRow(wireID: wireID)
            loaded.locator = SyncJSON.stored(values.text(0))
            loaded.position = values.integer(1)
            loaded.readAt = values.real(2)
            loaded.reviewDepth = values.text(3)
            loaded.furthestEpoch = values.integer(4)
            loaded.furthest = values.real(5)
            loaded.completedAt = values.real(6)
            loaded.consumedAt = values.real(7)
            loaded.lastReadAt = values.real(8)
            loaded.listen = SyncJSON.stored(values.text(9))
            loaded.media = SyncJSON.stored(values.text(10))
            loaded.watchedSeconds = values.real(11)
            loaded.lastContext = SyncJSON.stored(values.text(12))
            loaded.walkVariants = SyncJSON.stored(values.text(13))?.objectValue ?? [:]
            loaded.discussed = SyncJSON.stored(values.text(14))?.arrayValue?.compactMap(\.stringValue)
            loaded.understanding = SyncJSON.stored(values.text(15))
            loaded.understandingPath = values.text(16)
            row = loaded
        }
        return row
    }

    /// Writes the row whole as an upsert, so the outbox records only the columns that changed.
    func save(_ connection: SQLiteConnection) throws {
        let assignments = Self.columns.map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
        try connection.execute("""
            INSERT INTO reading_states (wire_id, \(Self.columns.joined(separator: ", ")))
            VALUES (?\(String(repeating: ", ?", count: Self.columns.count)))
            ON CONFLICT(wire_id) DO UPDATE SET \(assignments)
        """, [
            .text(wireID), .text(SyncJSON.storedText(locator)), .integer(position), .real(readAt), .text(reviewDepth), .integer(furthestEpoch),
            .real(furthest), .real(completedAt), .real(consumedAt), .real(lastReadAt), .text(SyncJSON.storedText(listen)), .text(SyncJSON.storedText(media)),
            .real(watchedSeconds), .text(SyncJSON.storedText(lastContext)), .text(walkVariants.isEmpty ? nil : SyncJSON.storedText(.object(walkVariants))),
            .text(discussed.map { SyncJSON.storedText(.array($0.map(SyncJSON.string))) } ?? nil), .text(SyncJSON.storedText(understanding)), .text(understandingPath),
        ])
    }
}

// MARK: - Locators

/// The Mac readers' resume locators (`EPUBReadingPositionLocator`, `ArticleReadingPositionLocator`,
/// `VideoWatchProgress`, each a JSON string in `reading_position_locator`) as the record's Locator
/// (§3.3), and back. The Mac's own string rides along under `mac`, so a round trip gives it back byte
/// for byte; a Locator another client wrote is read from its kind's keys. A PDF's place is the page
/// column, never a locator string.
enum ReadingLocatorCodec {
    /// The kind of a Mac string no other client reads.
    static let macKind = "mac"

    static func wire(macLocator: String) -> SyncJSON {
        var locator: [String: SyncJSON] = ["t": .string(macKind)]
        if let object = (try? SyncJSON(parsing: Data(macLocator.utf8)))?.objectValue {
            if let fraction = object["webScrollFraction"]?.numberValue {
                locator = ["t": .string("web"), "fraction": .number(fraction)]
            } else if let href = object["relativePath"]?.stringValue, let fraction = object["scrollFraction"]?.numberValue {
                locator = ["t": .string("epub"), "href": .string(href), "fraction": .number(fraction)]
            } else if let seconds = object["positionSeconds"]?.numberValue, let watched = object["watchedSeconds"]?.numberValue {
                locator = ["t": .string("media"), "seconds": .number(seconds), "watched": .number(watched)]
                if let duration = object["durationSeconds"]?.numberValue { locator["duration"] = .number(duration) }
            }
        }
        locator["mac"] = .string(macLocator)
        return .object(locator)
    }

    /// The Locator of a PDF page index.
    static func wire(page: Int64) -> SyncJSON {
        .object(["t": .string("pdf"), "page": SyncJSON(page)])
    }

    /// The Mac reader's string for a Locator: the one it was made from, else one built from a web,
    /// EPUB or media Locator's keys; nil for a PDF (its page is the page column) and for a kind no Mac
    /// reader keeps.
    static func macLocator(wire: SyncJSON?) -> String? {
        guard let object = wire?.objectValue else { return nil }
        if let mac = object["mac"]?.stringValue { return mac }
        func encoded(_ fields: [String: SyncJSON]) -> String { String(decoding: SyncJSON.object(fields).serialized(), as: UTF8.self) }
        switch object["t"]?.stringValue {
        case "web":
            return object["fraction"]?.numberValue.map { encoded(["webScrollFraction": .number($0)]) }
        case "epub":
            guard let href = object["href"]?.stringValue, let fraction = object["fraction"]?.numberValue else { return nil }
            return encoded(["relativePath": .string(href), "scrollFraction": .number(fraction)])
        case "media":
            guard let seconds = object["seconds"]?.numberValue else { return nil }
            var fields: [String: SyncJSON] = [
                "positionSeconds": .number(seconds), "watchedSeconds": .number(object["watched"]?.numberValue ?? seconds),
            ]
            if let duration = object["duration"]?.numberValue { fields["durationSeconds"] = .number(duration) }
            return encoded(fields)
        default:
            return nil
        }
    }

    /// `macLocator(wire:)` in SQL over a column holding a Locator's JSON, for the source view.
    static func macLocatorSQL(_ column: String) -> String {
        """
        COALESCE(json_extract(\(column), '$.mac'), CASE json_extract(\(column), '$.t')
                    WHEN 'web' THEN json_object('webScrollFraction', json_extract(\(column), '$.fraction'))
                    WHEN 'epub' THEN json_object('relativePath', json_extract(\(column), '$.href'), 'scrollFraction', json_extract(\(column), '$.fraction'))
                    WHEN 'media' THEN json_object('durationSeconds', json_extract(\(column), '$.duration'),
                        'positionSeconds', json_extract(\(column), '$.seconds'),
                        'watchedSeconds', COALESCE(json_extract(\(column), '$.watched'), json_extract(\(column), '$.seconds')))
                END)
        """
    }

    /// How far into the whole source a Mac locator is, 0…1 (`SourceProgressDepth`'s rule): a web
    /// article's or an EPUB chapter's scroll, a video's watched share. Nil when it does not say.
    static func fraction(macLocator: String?) -> Double? {
        guard let macLocator, let locator = wire(macLocator: macLocator).objectValue else { return nil }
        switch locator["t"]?.stringValue {
        case "web", "epub":
            return locator["fraction"]?.numberValue.map { min(max($0, 0), 1) }
        case "media":
            guard let duration = locator["duration"]?.numberValue, duration > 0, let watched = locator["watched"]?.numberValue else { return nil }
            return min(max(watched / duration, 0), 1)
        default:
            return nil
        }
    }
}

// MARK: - Walks

/// A walk's progress (`WalkthroughProgress`, kept whole in `walkthrough_progress.progress_json`) as the
/// record's `walk` variant (§3.5.18): `{currentStepID, revealedBeats, playedStepIDs, outcomes, chatID,
/// at}`, outcomes as raw strings so one a later build adds survives.
enum WalkProgressCodec {
    static func wire(progressJSON: String) -> SyncJSON? {
        guard let object = SyncJSON.stored(progressJSON)?.objectValue else { return nil }
        var walk: [String: SyncJSON] = [
            "revealedBeats": object["revealed_beats"] ?? .object([:]),
            "playedStepIDs": object["played_step_ids"] ?? .array([]),
            "outcomes": object["outcomes"] ?? .object([:]),
        ]
        if let step = object["current_step_id"], !step.isNull { walk["currentStepID"] = step }
        if let chat = object["chat_session_id"], !chat.isNull { walk["chatID"] = chat }
        if let updated = object["updated_at"]?.numberValue { walk["at"] = SyncJSON(SyncTime.milliseconds(cocoaSeconds: updated)) }
        return .object(walk)
    }

    /// The progress row's JSON for `subjectID` (the keys `WalkthroughProgress` decodes), and its time.
    static func progress(wire: SyncJSON, subjectID: String) -> (json: String, updatedAt: Double)? {
        guard let walk = wire.objectValue else { return nil }
        let updatedAt = walk["at"]?.int64Value.map { SyncTime.cocoaSeconds(milliseconds: $0) } ?? 0
        var object: [String: SyncJSON] = [
            "subject_id": .string(subjectID),
            "revealed_beats": walk["revealedBeats"] ?? .object([:]),
            "played_step_ids": walk["playedStepIDs"] ?? .array([]),
            "outcomes": walk["outcomes"] ?? .object([:]),
            "updated_at": .number(updatedAt),
        ]
        if let step = walk["currentStepID"], !step.isNull { object["current_step_id"] = step }
        if let chat = walk["chatID"], !chat.isNull { object["chat_session_id"] = chat }
        return (String(decoding: SyncJSON.object(object).serialized(), as: UTF8.self), updatedAt)
    }
}

// MARK: - The projection

/// A ReadingState's local rows: the `reading_states` row, the walk's progress row and the source's
/// Understanding row, each optional (any one makes the record).
struct ReadingStateRows: Equatable, Sendable {
    var targetID: String
    var targetKind: String
    var state: ReadingStateRow?
    var walkJSON: String?
    /// `source_understanding.discussed_idea_ids` when the source has an Understanding row.
    var understandingDiscussed: [String]?
}

/// The ReadingState record's projection (§3.5.18): private to the member, created on the first real
/// change (opening writes nothing, P9), and never deleted because its source went. It reads
/// `reading_states`, `walkthrough_progress` (`walk.main`) and `source_understanding`
/// (`discussedIdeaKeys`), all keyed by the target's wire id, so no `sources` row feeds it and a team
/// copy can never write a stale copy's position over the personal one (§4.3).
struct ReadingStateProjection: RecordProjection {
    var recordType: SyncRecordType { .readingState }

    static let mainWalk = "main"

    static func targetID(ofRecord wireID: String) -> String {
        wireID.hasPrefix("rs:") ? String(wireID.dropFirst(3)) : wireID
    }

    var tables: [ProjectedTable] {
        func table(_ name: String, key: String, synced: [String]) -> ProjectedTable {
            let recordIDSQL: @Sendable (String) -> String = { "'rs:' || \($0).\(key)" }
            return ProjectedTable(
                name, localKey: [key], keyColumns: [key], syncedColumns: synced, recordTypes: [.readingState],
                record: { values in
                    values[key]?.textValue.map {
                        let id = SyncIdentity.readingStateID(targetID: $0)
                        return RowRecord(type: .readingState, localID: id, personalID: id)
                    }
                },
                localIDSQL: recordIDSQL, personalIDSQL: recordIDSQL
            )
        }
        return [
            table("reading_states", key: "wire_id", synced: ReadingStateRow.columns.filter { $0 != "understanding_path" }),
            table("walkthrough_progress", key: "subject_id", synced: ["progress_json"]),
            table("source_understanding", key: "source_id", synced: ["discussed_idea_ids"]),
        ]
    }

    private static func column(_ names: String...) -> FieldFeed { .columns(table: "reading_states", names) }

    var feeds: [String: FieldFeed] {
        let existence: FieldFeed = .anyOf([
            .rowExistence(table: "reading_states"), .rowExistence(table: "walkthrough_progress"), .rowExistence(table: "source_understanding"),
        ])
        return [
            "targetKind": existence, "targetID": existence,
            "locator": Self.column("locator_json", "position"), "furthest": Self.column("furthest_epoch", "furthest"),
            "readAt": Self.column("read_at"), "completedAt": Self.column("completed_at"), "consumedAt": Self.column("consumed_at"),
            "lastReadAt": Self.column("last_read_at"), "reviewDepth": Self.column("review_depth"), "listen": Self.column("listen_json"),
            "media": Self.column("media_json"), "watchedSeconds": Self.column("watched_seconds"),
            "lastContext": Self.column("last_context_json"), "understanding": Self.column("understanding_json"),
            "walk": .anyOf([.columns(table: "walkthrough_progress", ["progress_json"]), Self.column("walk_variants_json")]),
            "discussedIdeaKeys": .anyOf([.columns(table: "source_understanding", ["discussed_idea_ids"]), Self.column("discussed_json")]),
        ]
    }

    /// Never used: the rows always load (a record whose every row went still says so, field by field).
    var missingRow: MissingRowOutcome { .fields([:]) }
    var missingParentNeverDeletes: Bool { true }
    var priority: OutboxPriority { .personal }
    /// A reading position moves with every scroll: 30 s (§6.6 step 4).
    var debounce: TimeInterval { 30 }

    func loadRows(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws -> ReadingStateRows? {
        try Self.rows(targetID: Self.targetID(ofRecord: record.wireID), connection: connection)
    }

    static func rows(targetID: String, connection: SQLiteConnection) throws -> ReadingStateRows {
        var rows = ReadingStateRows(targetID: targetID, targetKind: "source")
        // An animation's walk is about an artifact; a source's state about the source, which may not be
        // here yet (a ReadingState can arrive first, §5.7).
        if try connection.scalarInteger("SELECT EXISTS(SELECT 1 FROM sources WHERE wire_key = ?)", [.text(targetID)]) != 1,
           try connection.scalarInteger("SELECT EXISTS(SELECT 1 FROM global_artifacts WHERE wire_key = ?)", [.text(targetID)]) == 1 {
            rows.targetKind = "artifact"
        }
        rows.state = try ReadingStateRow.load(targetID, connection: connection)
        rows.walkJSON = try connection.scalarText("SELECT progress_json FROM walkthrough_progress WHERE subject_id = ?", [.text(targetID)])
        rows.understandingDiscussed = try connection.scalarText(
            "SELECT discussed_idea_ids FROM source_understanding WHERE source_id = ?", [.text(targetID)]
        ).map { SyncJSON.stored($0)?.arrayValue?.compactMap(\.stringValue) ?? [] }
        return rows
    }

    static func encodeRows(_ rows: ReadingStateRows) -> [String: SyncJSON] {
        let state = rows.state ?? ReadingStateRow(wireID: rows.targetID)
        func ms(_ seconds: Double?) -> SyncJSON { seconds.map { SyncJSON(SyncTime.milliseconds(cocoaSeconds: $0)) } ?? .null }
        var walk = state.walkVariants
        if let json = rows.walkJSON, let main = WalkProgressCodec.wire(progressJSON: json) { walk[mainWalk] = main }
        let discussed = rows.understandingDiscussed ?? state.discussed ?? []
        var fields: [String: SyncJSON] = [
            "targetKind": .string(rows.targetKind),
            "targetID": .string(rows.targetID),
            "locator": state.locator ?? state.position.map(ReadingLocatorCodec.wire(page:)) ?? .null,
            "furthest": state.furthest.map { .array([SyncJSON(state.furthestEpoch ?? 0), .number($0)]) } ?? .null,
            "readAt": ms(state.readAt),
            "completedAt": ms(state.completedAt),
            "consumedAt": ms(state.consumedAt),
            "lastReadAt": ms(state.lastReadAt),
            "reviewDepth": state.reviewDepth.map(SyncJSON.string) ?? .null,
            "listen": state.listen ?? .null,
            "media": state.media ?? .null,
            "watchedSeconds": state.watchedSeconds.map(SyncJSON.number) ?? .null,
            "lastContext": state.lastContext ?? .null,
            "walk": .object(walk),
            "discussedIdeaKeys": .object(Dictionary(discussed.map { ($0, SyncJSON.bool(true)) }, uniquingKeysWith: { first, _ in first })),
        ]
        if let understanding = state.understanding { fields["understanding"] = understanding }
        return fields
    }

    func apply(_ envelope: SyncEnvelope, to record: ProjectionRecordRef, connection: SQLiteConnection) throws -> ProjectionApplyOutcome {
        guard !record.zone.isSpace else { return .projected }
        let fields = envelope.fields
        let targetID = fields["targetID"]?.stringValue ?? Self.targetID(ofRecord: record.wireID)
        let held = try ReadingStateRow.load(targetID, connection: connection)
        var state = held ?? ReadingStateRow(wireID: targetID)
        func seconds(_ field: String) -> Double? { fields[field]?.int64Value.map { SyncTime.cocoaSeconds(milliseconds: $0) } }

        if let locator = fields["locator"] {
            state.locator = locator.isNull ? nil : locator
            if locator.isNull {
                state.position = nil
            } else if locator["t"]?.stringValue == "pdf" {
                state.position = locator["page"]?.int64Value
            }
        }
        if let furthest = fields["furthest"] {
            let pair = furthest.arrayValue ?? []
            state.furthestEpoch = pair.first?.int64Value
            state.furthest = pair.count > 1 ? pair[1].numberValue : nil
        }
        if fields["readAt"] != nil { state.readAt = seconds("readAt") }
        if fields["completedAt"] != nil { state.completedAt = seconds("completedAt") }
        if fields["consumedAt"] != nil { state.consumedAt = seconds("consumedAt") }
        if fields["lastReadAt"] != nil { state.lastReadAt = seconds("lastReadAt") }
        if let value = fields["reviewDepth"] { state.reviewDepth = value.stringValue }
        if let value = fields["listen"] { state.listen = value.isNull ? nil : value }
        if let value = fields["media"] { state.media = value.isNull ? nil : value }
        if let value = fields["watchedSeconds"] { state.watchedSeconds = value.numberValue }
        if let value = fields["lastContext"] { state.lastContext = value.isNull ? nil : value }
        if let value = fields["understanding"] { state.understanding = value.isNull ? nil : value }

        // The walk: `main` is the walk's own progress row; other variants are held for the record.
        if let walk = fields["walk"]?.objectValue {
            state.walkVariants = walk.filter { $0.key != Self.mainWalk && !$0.value.isNull }
            if let main = walk[Self.mainWalk], !main.isNull, let progress = WalkProgressCodec.progress(wire: main, subjectID: targetID) {
                try connection.execute("""
                    INSERT INTO walkthrough_progress (subject_id, progress_json, updated_at) VALUES (?, ?, ?)
                    ON CONFLICT(subject_id) DO UPDATE SET progress_json = excluded.progress_json, updated_at = excluded.updated_at
                """, [.text(targetID), .text(progress.json), .real(progress.updatedAt)])
            } else {
                try connection.execute("DELETE FROM walkthrough_progress WHERE subject_id = ?", [.text(targetID)])
            }
        }
        // The ideas discussed: on the Understanding row when this Mac holds one, else held here.
        if let keys = fields["discussedIdeaKeys"]?.objectValue {
            let members = keys.compactMap { $0.value.boolValue == true ? $0.key : nil }.sorted()
            if try connection.scalarInteger("SELECT EXISTS(SELECT 1 FROM source_understanding WHERE source_id = ?)", [.text(targetID)]) == 1 {
                try connection.execute(
                    "UPDATE source_understanding SET discussed_idea_ids = ? WHERE source_id = ?",
                    [.text(SyncJSON.storedText(.array(members.map(SyncJSON.string)))), .text(targetID)]
                )
                state.discussed = nil
            } else {
                state.discussed = members.isEmpty ? nil : members
            }
        }
        // A notebook item is complete when its source is, in every notebook that holds it (§10).
        if fields["completedAt"] != nil, state.completedAt != held?.completedAt {
            try connection.execute("""
                UPDATE learning_goal_items SET completed_at = ?
                WHERE source_id = ? OR source_id IN (SELECT id FROM sources WHERE wire_key = ?)
            """, [.real(state.completedAt), .text(targetID), .text(targetID)])
        }
        if held != nil || !state.isEmpty {
            try state.save(connection)
        }
        return .projected
    }

    func applyDeletion(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws {
        let targetID = Self.targetID(ofRecord: record.wireID)
        try connection.execute("DELETE FROM reading_states WHERE wire_id = ?", [.text(targetID)])
        try connection.execute("DELETE FROM walkthrough_progress WHERE subject_id = ?", [.text(targetID)])
    }
}
