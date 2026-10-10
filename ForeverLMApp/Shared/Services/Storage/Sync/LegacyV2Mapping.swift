import CryptoKit
import Foundation

// MARK: - What an old record gives (docs/cloudkit-schema-design.md §10, "Who owns what"; §13.6)

/// How an old record gives a v2 record (§10, "Who owns what").
enum LegacyGiving: String, Sendable, Equatable, CaseIterable {
    /// The old record owns it, as itself or as a child its payload holds. Only this mapping creates it,
    /// whole; the old record's deletion, or its mapping no longer giving it, removes it.
    case owns
    /// Nobody owns it: per-member state and history, and a podcast show's or YouTube channel's
    /// Collection. Every feeder gives all its required fields, so whichever gives it first creates it;
    /// a value is applied when it changes, and no old-world change removes it.
    case creates
    /// Nobody owns it, and this old record only creates it: a playlist's Collection that no
    /// `VideoPlaylist` record gives, from a member's group id (R7-m5). Once it exists, nothing changes.
    case createsOnly
    /// Values into a record another old record owns, or into a `Device` or a space root: applied to a
    /// record that exists; a value for one that does not yet waits, up to 30 days (§13.6).
    case feeds
    /// Turns a record off or clears a field where one exists (a Mark's `on`, an Enrollment's focus): it
    /// creates nothing and never waits, since an old record's default state ("not wanted", "not
    /// followed") is no change to a record that was never made.
    case clears
}

/// One v2 record an old record gives, with the fields it gives.
struct LegacyV2Record: Equatable, Sendable {
    let type: SyncRecordType
    /// The record's logical id (its wire id).
    let id: String
    /// The fields the old record gives, as the record's projection encodes them. A key the old
    /// payload omits gives nothing (R6-m4); `.null` clears a field the old record owns or alone feeds.
    var fields: [String: SyncJSON]
    var giving: LegacyGiving
    /// The set and map fields given whole: an element the base lists for this old record that the
    /// mapping no longer gives leaves the record. An owner gives its structure whole; a feeder only a
    /// field it alone feeds (a `notebook.collections.*` row's ids, R7-m1, R8-m7).
    var wholeFields: Set<String> = []
    /// Fields hashed by a value the record does not carry here: a Doc's `body` by the old payload's
    /// `bodyRevision`, whether or not its package was fetched (R5-2).
    var hashOverrides: [String: String] = [:]
    /// Fields only a creation takes from this old record (a required field with a default, such as an
    /// Enrollment's `status`); a record that exists keeps its own. They are not hashed.
    var createOnlyFields: Set<String> = []
    /// The space a `Team-*` record's copy lives in (§13.7); nil for the personal library.
    var spaceID: String?

    var owned: Bool { giving == .owns }
    var key: String { "\(type.rawValue):\(id)" }
}

/// A kind of child record an old payload may say nothing about: a type, and for an Entry its item kind.
struct LegacyChildScope: Hashable, Sendable {
    let type: SyncRecordType
    var itemKind: String?

    init(type: SyncRecordType, itemKind: String? = nil) {
        self.type = type
        self.itemKind = itemKind
    }

    /// Whether a record the base lists falls in the scope.
    func covers(type: SyncRecordType, id: String) -> Bool {
        guard type == self.type else { return false }
        guard let itemKind else { return true }
        return EntryID(id)?.itemKind == itemKind
    }
}

/// Everything one old record gives.
struct LegacyMapping: Equatable, Sendable {
    let entity: CloudKitSyncEntity
    let logicalKey: String
    var records: [LegacyV2Record] = []
    /// The children the old payload says nothing about this time (an omitted key, R6-m4): records in
    /// these scopes the base lists as owned by this old record are not removed for being absent.
    var silentChildren: Set<LegacyChildScope> = []

    init(entity: CloudKitSyncEntity, logicalKey: String, records: [LegacyV2Record] = [], silentChildren: Set<LegacyChildScope> = []) {
        self.entity = entity
        self.logicalKey = logicalKey
        self.records = records
        self.silentChildren = silentChildren
    }

    /// Whether the payload is silent on a record of this type and id (R6-m4).
    func isSilent(on type: SyncRecordType, id: String) -> Bool {
        silentChildren.contains { $0.covers(type: type, id: id) }
    }

    func record(_ type: SyncRecordType, _ id: String) -> LegacyV2Record? {
        records.first { $0.type == type && $0.id == id }
    }

    /// The field hashes of every record it gives, by record key (`<type>:<id>`).
    var hashes: [String: [String: String]] {
        Dictionary(records.map { ($0.key, LegacyFieldHashes.hashes($0)) }, uniquingKeysWith: { first, _ in first })
    }

    /// The old record's entry in this Mac's `ck_legacy_snapshot.field_hashes` and in the shared base's
    /// shards (`ZoneRoot.legacyBase`): its `waiting` flag and, per v2 record it gives, the owner flag and
    /// the field hashes. Two Macs mapping one old record write the same bytes.
    func baseEntry(waiting: Bool = false) -> SyncJSON {
        var records: [String: SyncJSON] = [:]
        // A `clears` record is listed too, never owned: its hashes are what a later pass compares, so an old
        // record that is written again with the state it already gave does not wipe what the new world set
        // since (F2).
        for record in self.records {
            let hashes = LegacyFieldHashes.hashes(record)
            records[record.key] = .object([
                "o": .bool(record.owned),
                "h": .object(hashes.mapValues(SyncJSON.string)),
            ])
        }
        return .object(["w": .bool(waiting), "r": .object(records)])
    }
}

// MARK: - Field hashes

/// The hashes the catch-up snapshot and the shared base keep per v2 record and field (§3.5.1, §13.6):
/// the first 16 hex characters of sha256 over the value's canonical JSON. A set or map field hashes
/// per element under `<field>/<element>`, so the ids a row gave are known once it is deleted (R8-m7);
/// a body hashes by its content hash, a Doc's being the old `bodyRevision` (R5-2).
enum LegacyFieldHashes {
    static func hash(_ value: SyncJSON) -> String {
        String(SyncIdentity.sha256Hex(value.serialized()).prefix(16))
    }

    static func hashes(_ record: LegacyV2Record) -> [String: String] {
        var hashes: [String: String] = [:]
        let spec = record.type.spec
        for (field, value) in record.fields where !record.createOnlyFields.contains(field) {
            if let kind = spec.field(field)?.kind, kind != .scalar, let elements = value.objectValue {
                for (element, elementValue) in elements { hashes["\(field)/\(element)"] = hash(elementValue) }
            } else if let content = bodyHash(record.type, field, value) {
                hashes[field] = content
            } else {
                hashes[field] = hash(value)
            }
        }
        for (field, value) in record.hashOverrides { hashes[field] = value }
        return hashes
    }

    /// A body field's content hash: the hash its FileRef carries (a Doc's package hash is the old
    /// `bodyRevision`; a Notes Doc's is the hash of its encoded text, as WP8's Notes Doc lays it out).
    static func bodyHash(_ type: SyncRecordType, _ field: String, _ value: SyncJSON) -> String? {
        guard type == .artifact, field == "body", let file = FileRef(json: value) else { return nil }
        return file.hash
    }
}

// MARK: - The ownership relation, as a table

/// Every (old type, v2 type) pair the mapping gives and how (§10, both tables). `LegacyMappingParityTests`
/// requires every record a mapping gives to match its pair here, so the relation exists once.
enum LegacyOwnership {
    static let pairs: [CloudKitSyncEntity: [SyncRecordType: Set<LegacyGiving>]] = [
        // A Source owns its record and, while its group id names a playlist, its playlist Entry
        // (R6-2); its show's or channel's Collection has no owner, and its playlist's Collection,
        // when no VideoPlaylist record gives one, is created from the group id only (R6-m3, R7-m5).
        .source: [
            .source: [.owns], .entry: [.owns], .collection: [.creates, .createsOnly], .readingState: [.creates, .clears], .mark: [.creates, .clears],
        ],
        .book: [.collection: [.owns]],
        .videoPlaylist: [.collection: [.owns], .mark: [.creates, .clears]],
        .meetingGroup: [.collection: [.owns], .task: [.owns], .source: [.feeds]],
        // A notebook's sidebar place is `studio.projectOrder`'s (WP8 derives none from `sort_order`).
        .learningGoal: [.notebook: [.owns], .goal: [.owns], .entry: [.owns], .artifact: [.owns], .readingState: [.creates]],
        .course: [.course: [.owns], .lesson: [.owns], .quiz: [.owns], .entry: [.owns]],
        .reviewSession: [.chat: [.owns], .exchange: [.owns], .mark: [.creates]],
        // A draft deck gives no Artifact, only its cards' draft Cards, each created once (§13.6).
        .artifact: [.artifact: [.owns], .card: [.createsOnly]],
        .artifactComment: [.comment: [.owns]],
        .idea: [.idea: [.owns]],
        .researchDirection: [.idea: [.owns]],
        .skill: [.artifact: [.owns]],
        .notebookTask: [.task: [.owns]],
        .shareRequest: [.task: [.owns]],
        .scheduledTask: [.automation: [.owns]],
        .scheduledSource: [.placement: [.owns], .activityLog: [.creates]],
        .memoryItem: [.card: [.owns]],
        // A settings key or a `notebookCollection.*` row owns its Setting; a domain prefix feeds what
        // its §10 row names. A deck's state feeds the Card its Memory item gives, and creates the Card of
        // a skipped draft, which no old record owns; `meetingFolder.image.*` is a Setting here (its icon
        // file is the asset pass's).
        .preference: [
            .setting: [.owns], .notebookState: [.creates], .readingState: [.creates], .enrollment: [.creates, .clears],
            .sitting: [.creates], .mark: [.creates, .clears], .card: [.feeds, .creates], .device: [.feeds],
        ],
        .memoryAttempt: [.sitting: [.creates]],
        .memoryReviewActivity: [.activityLog: [.creates]],
        // A source's `ideas` and `citedPapers` satellites come with the asset pass, not as fields.
        .sourceIdea: [.mark: [.creates, .clears]],
        .videoCitedPaper: [.mark: [.creates, .clears]],
        .walkthroughProgress: [.readingState: [.creates]],
        .sourceHighlight: [.highlight: [.creates]],
        .hiddenSource: [.mark: [.creates]],
        .hiddenPodcastShow: [.mark: [.creates]],
        .hiddenYouTubeChannel: [.mark: [.creates]],
        .hiddenArtifact: [.mark: [.creates]],
        .hiddenReviewSession: [.mark: [.creates]],
        .dismissedSource: [.mark: [.creates]],
        .team: [.zoneRoot: [.feeds]],
    ]

    /// The types §10 drops: they give nothing.
    static let dropped: Set<CloudKitSyncEntity> = [.chatContext, .dayPlan, .researchCanvas, .aiUsageEvent]

    /// The v2 types nobody owns, per member or catalog, that no old-world change removes (§10).
    static let neverRemoved: Set<SyncRecordType> = [
        .readingState, .notebookState, .mark, .highlight, .card, .enrollment, .sitting, .activityLog,
    ]

    static func allows(_ entity: CloudKitSyncEntity, _ record: LegacyV2Record) -> Bool {
        pairs[entity]?[record.type]?.contains(record.giving) == true
    }
}

// MARK: - What the mapping reads besides the old record

/// One lesson item as this Mac holds it: what the activation derived for it, which stays.
struct LegacyHeldLessonItem: Equatable, Sendable {
    var orderKey: String?
    var slot: Int?
    var spanJSON: String?
}

/// The cross-record facts a mapping needs and one old record does not carry: what a group id names, a
/// walk naming a chat, a team copy's wire id, and what this Mac already derived and keeps (an order key
/// in order, a chat's kind, a lesson item's slot), which the activation also leaves as it is. On the Mac
/// they come from the local tables the projections keep (`StoreLegacyMappingContext`); a pass may add
/// what it has decoded but not yet applied.
protocol LegacyMappingContext {
    /// The kind of collection a source's group id names (a book or a meeting series), or nil.
    func collectionKind(groupID: String) throws -> SourceCollectionMembership.Kind?
    /// Whether a `VideoPlaylist` record (a `video_playlists` row) holds the playlist.
    func holdsVideoPlaylist(_ groupID: String) throws -> Bool
    /// A followed playlist's title, which a video's channel line may hold instead of a channel name.
    func videoPlaylistTitle(_ groupID: String) throws -> String?
    /// The wire id of a record a `Team-*` zone holds under `oldID` (`ck_identity`); `oldID` itself for
    /// the personal library.
    func wireID(_ type: SyncRecordType, oldID: String, teamID: String?) throws -> String
    /// A source's wire id (a team copy's is the canonical personal one, §13.7); the id itself when this
    /// Mac holds no such source.
    func sourceWireID(_ sourceID: String) throws -> String
    func sourceExists(_ sourceID: String) throws -> Bool
    func isArchivedSource(_ sourceID: String) throws -> Bool
    func learningGoalExists(_ id: String) throws -> Bool

    /// The kind a notebook or Goal row was classified as (never inferred again, b1).
    func heldEntityKind(_ goalID: String) throws -> String?
    /// A pool's order keys by source.
    func heldEntryOrderKeys(goalID: String) throws -> [String: String]
    func heldResearchQuestions(notebookID: String) throws -> [NotebookResearchQuestions.Row]

    func boardTasks(notebookID: String) throws -> [LegacyBoardTask]
    /// A Task's kind as the replica holds it (S: a later assignee never turns a to-do into an assignment).
    func heldTaskKind(_ taskID: String) throws -> String?

    func heldCourseCreatedAt(_ courseID: String) throws -> Double?
    /// A course's lesson order keys by lecture.
    func heldLessonOrderKeys(courseID: String) throws -> [String: String]
    /// A lecture's items by item id.
    func heldLessonItems(lectureID: String) throws -> [String: LegacyHeldLessonItem]
    /// A source unit's kind and locator (a textbook reading's pages).
    func sourceUnit(_ unitID: String) throws -> (kind: String, locator: String)?
    func heldQuiz(_ quizID: String) throws -> (revision: Int64, questionsJSON: String)?

    func heldChat(_ chatID: String) throws -> LegacyHeldChat?
    /// Whether a walk's progress names the chat (`ChatKindClassifier` evidence).
    func walkNamesChat(_ chatID: String) throws -> Bool
    /// The notebook a chat filed under `goalID` is in (`ChatProjection.notebookID`).
    func chatNotebookID(goalID: String?) throws -> String?
    func heldExchange(_ exchangeID: String) throws -> LegacyHeldExchange?

    func hasLocalSite(_ artifactID: String) throws -> Bool
    func heldCardState(_ cardID: String) throws -> CardRows.State?

    /// The fingerprint of a Memory item's immutable curriculum, as an attempt recorded against it
    /// carries (an older attempt's payload names none); nil when this Mac holds no such item.
    func curriculumFingerprint(itemID: String) throws -> String?
    /// The Sitting part that already holds an answer: an old attempt joins it again.
    func heldSittingID(answerID: String) throws -> String?
    /// What a per-member key names, `source` or `artifact` (an animation's walk).
    func readingTargetKind(_ targetID: String) throws -> String
    /// This device's sync id; nil before its clock exists.
    func thisDeviceID() throws -> String?
    /// Every connector-health preference row this Mac holds, decoded, by key.
    func connectorHealthValues() throws -> [String: Any]
    /// The shows this Mac holds blocked from import.
    func heldBlockedShows() throws -> [String]

    /// The notebooks that existed when this Mac's activation began (a row lists the pinned ones; every other
    /// of them is not pinned). A notebook made since is the new world's, and no old row speaks for it.
    func notebookIDs() throws -> [String]
    /// The stamp pair of the Entry each of `sources` was unticked against, by source: the pair this Mac
    /// holds for it, else the one its Entry's stamps give now. A source in no Entry of the notebook's
    /// context is left out (an untick of it is not stored, §5.6), and a source whose Entry has no stamp to
    /// name yet is `NotebookStateRow.pendingPair`.
    func excludedPairs(notebookID: String, sources: [String]) throws -> [String: String]
    /// The space a team's records live in (§13.7): the one this Mac's `teams` row names, else the team's
    /// id, lowercased when it is a UUID. A team whose id is no UUID got a space of a new id, which only the
    /// row knows (F25).
    func spaceID(teamID: String?) -> String?
}

extension LegacyMappingContext {
    func spaceID(teamID: String?) -> String? {
        teamID.map { UUID(uuidString: $0).map { $0.uuidString.lowercased() } ?? $0 }
    }
}

/// The context read from this Mac's store: the tables the projections keep, which hold what this Mac
/// knows of the library under generation 2 and what the activation derived from generation-1 truth.
struct StoreLegacyMappingContext: LegacyMappingContext {
    let connection: SQLiteConnection
    static let libraryZoneKey = ReplicaZone.key(database: .private, zoneName: SyncZone.library.rawValue)

    private func exists(_ sql: String, _ value: String) throws -> Bool {
        try connection.scalarInteger("SELECT EXISTS(\(sql))", [.text(value)]) == 1
    }

    func collectionKind(groupID: String) throws -> SourceCollectionMembership.Kind? {
        if try exists("SELECT 1 FROM books WHERE id = ?", groupID) { return .book }
        if try exists("SELECT 1 FROM meeting_groups WHERE id = ?", groupID) { return .meetingSeries }
        return nil
    }

    func holdsVideoPlaylist(_ groupID: String) throws -> Bool {
        try exists("SELECT 1 FROM video_playlists WHERE id = ?", groupID)
    }

    func videoPlaylistTitle(_ groupID: String) throws -> String? {
        try connection.scalarText("SELECT title FROM video_playlists WHERE id = ?", [.text(groupID)])
    }

    func wireID(_ type: SyncRecordType, oldID: String, teamID: String?) throws -> String {
        guard teamID != nil else { return oldID }
        if type == .source { return try sourceWireID(oldID) }
        return try connection.scalarText(
            "SELECT wire_id FROM ck_identity WHERE record_type = ? AND local_id = ? ORDER BY zone_key LIMIT 1",
            [.text(type.rawValue), .text(oldID)]
        ) ?? oldID
    }

    func sourceWireID(_ sourceID: String) throws -> String {
        try connection.scalarText("SELECT COALESCE(wire_id, id) FROM sources WHERE id = ?", [.text(sourceID)]) ?? sourceID
    }

    func sourceExists(_ sourceID: String) throws -> Bool {
        try exists("SELECT 1 FROM sources WHERE id = ?", sourceID)
    }

    func isArchivedSource(_ sourceID: String) throws -> Bool {
        try exists("SELECT 1 FROM sources WHERE id = ? AND status = 'archived'", sourceID)
    }

    func learningGoalExists(_ id: String) throws -> Bool {
        try exists("SELECT 1 FROM learning_goals WHERE id = ?", id)
    }

    func heldEntityKind(_ goalID: String) throws -> String? {
        try connection.scalarText("SELECT entity_kind FROM learning_goals WHERE id = ?", [.text(goalID)])
    }

    func heldEntryOrderKeys(goalID: String) throws -> [String: String] {
        var keys: [String: String] = [:]
        try connection.query("SELECT source_id, order_key FROM learning_goal_items WHERE goal_id = ? AND order_key IS NOT NULL", [.text(goalID)]) { row in
            if let source = row.text(0), let key = row.text(1) { keys[source] = key }
        }
        return keys
    }

    func heldResearchQuestions(notebookID: String) throws -> [NotebookResearchQuestions.Row] {
        try NotebookResearchQuestions.rows(notebookID: notebookID, connection: connection)
    }

    func boardTasks(notebookID: String) throws -> [LegacyBoardTask] {
        var tasks: [LegacyBoardTask] = []
        try connection.query("SELECT id, sort_order, created_at, order_key FROM notebook_tasks WHERE notebook_id = ?", [.text(notebookID)]) { row in
            if let id = row.text(0) {
                tasks.append(LegacyBoardTask(id: id, sortOrder: row.real(1) ?? 0, createdAt: row.real(2) ?? 0, orderKey: row.text(3)))
            }
        }
        return tasks
    }

    func heldTaskKind(_ taskID: String) throws -> String? {
        try HeldRecord.envelope(.task, taskID, preferring: Self.libraryZoneKey, connection: connection)?.fields["kind"]?.stringValue
    }

    func heldCourseCreatedAt(_ courseID: String) throws -> Double? {
        var created: Double?
        try connection.query("SELECT created_at FROM courses WHERE id = ?", [.text(courseID)]) { created = $0.real(0) }
        return created
    }

    func heldLessonOrderKeys(courseID: String) throws -> [String: String] {
        var keys: [String: String] = [:]
        try connection.query("SELECT id, order_key FROM course_lectures WHERE course_id = ? AND order_key IS NOT NULL", [.text(courseID)]) { row in
            if let id = row.text(0), let key = row.text(1) { keys[id] = key }
        }
        return keys
    }

    func heldLessonItems(lectureID: String) throws -> [String: LegacyHeldLessonItem] {
        var items: [String: LegacyHeldLessonItem] = [:]
        try connection.query("SELECT id, order_key, span_slot, span_json FROM course_lecture_items WHERE lecture_id = ?", [.text(lectureID)]) { row in
            if let id = row.text(0) {
                items[id] = LegacyHeldLessonItem(orderKey: row.text(1), slot: row.integer(2).map(Int.init), spanJSON: row.text(3))
            }
        }
        return items
    }

    func sourceUnit(_ unitID: String) throws -> (kind: String, locator: String)? {
        var unit: (kind: String, locator: String)?
        try connection.query("SELECT kind, locator FROM source_units WHERE id = ?", [.text(unitID)]) { row in
            if let kind = row.text(0), let locator = row.text(1) { unit = (kind, locator) }
        }
        return unit
    }

    func heldQuiz(_ quizID: String) throws -> (revision: Int64, questionsJSON: String)? {
        var quiz: (revision: Int64, questionsJSON: String)?
        try connection.query("SELECT revision, questions_json FROM course_quizzes WHERE id = ?", [.text(quizID)]) { row in
            quiz = (row.integer(0) ?? 1, row.text(1) ?? "[]")
        }
        return quiz
    }

    func heldChat(_ chatID: String) throws -> LegacyHeldChat? {
        var chat: LegacyHeldChat?
        try connection.query(
            "SELECT chat_kind, marks_reviewed, context_mode, goal_id, kind, briefing FROM review_sessions WHERE id = ?", [.text(chatID)]
        ) { row in
            chat = LegacyHeldChat(
                chatKind: row.text(0), marksReviewed: row.integer(1).map { $0 != 0 }, contextMode: row.text(2), goalID: row.text(3),
                legacyKind: row.text(4), briefing: row.text(5)
            )
        }
        chat?.replicaStatus = try HeldRecord.envelope(.chat, chatID, preferring: Self.libraryZoneKey, connection: connection)?.fields["status"]?.stringValue
        return chat
    }

    func walkNamesChat(_ chatID: String) throws -> Bool {
        try exists(
            "SELECT 1 FROM walkthrough_progress WHERE json_valid(progress_json) AND json_extract(progress_json, '$.chat_session_id') = ?", chatID
        )
    }

    func chatNotebookID(goalID: String?) throws -> String? {
        try ChatProjection.notebookID(goalID: goalID, connection: connection)
    }

    func heldExchange(_ exchangeID: String) throws -> LegacyHeldExchange? {
        try HeldRecord.envelope(.exchange, exchangeID, preferring: Self.libraryZoneKey, connection: connection).map {
            LegacyHeldExchange(seq: $0.fields["seq"], createdAt: $0.fields["createdAt"])
        }
    }

    func hasLocalSite(_ artifactID: String) throws -> Bool {
        (connection as? KnowledgeStore)?.hasLocalSite(artifactID) ?? false
    }

    func heldCardState(_ cardID: String) throws -> CardRows.State? {
        try CardProjection.loadRows(id: cardID, connection: connection)?.state
    }

    func curriculumFingerprint(itemID: String) throws -> String? {
        try CardProjection.loadRows(id: itemID, connection: connection)?.item.map(MemoryTutorIdentity.immutableCurriculumFingerprint)
    }

    func heldSittingID(answerID: String) throws -> String? {
        try connection.scalarText("SELECT sitting_id FROM memory_sitting_answers WHERE answer_id = ?", [.text(answerID)])
    }

    func readingTargetKind(_ targetID: String) throws -> String {
        if try connection.scalarInteger("SELECT EXISTS(SELECT 1 FROM sources WHERE wire_key = ?)", [.text(targetID)]) != 1,
           try connection.scalarInteger("SELECT EXISTS(SELECT 1 FROM global_artifacts WHERE wire_key = ?)", [.text(targetID)]) == 1 {
            return "artifact"
        }
        return "source"
    }

    func thisDeviceID() throws -> String? {
        try MemorySyncDevice.current(connection)
    }

    func connectorHealthValues() throws -> [String: Any] {
        var rows: [String: Any] = [:]
        try connection.query("SELECT key, value FROM user_preferences WHERE key LIKE ?", [.text(ConnectorHealthMap.prefix + "%")]) { row in
            if let key = row.text(0), let value = row.text(1).flatMap(PreferenceStore.decodePlist) { rows[key] = value }
        }
        return rows
    }

    /// When this Mac's activation began (Cocoa seconds), which divides the old world's state from the new
    /// world's: an old row that does not list something made after it is not saying it is off. Nil with no
    /// journal, and nothing is then left out.
    private func activationStartedAt() throws -> Double? {
        var started: Double?
        // A store with no journal table (a generation-1 fixture) has no divide.
        try? connection.query("SELECT started_at FROM ck_activation WHERE id = 1", []) { started = $0.real(0) }
        return started
    }

    func heldBlockedShows() throws -> [String] {
        let started = try activationStartedAt()
        var names: [String] = []
        try connection.query("SELECT show_name, blocked_at FROM blocked_podcast_shows ORDER BY show_name", []) { row in
            guard let name = row.text(0) else { return }
            if let started, (row.real(1) ?? 0) > started { return }
            names.append(name)
        }
        return names
    }

    func notebookIDs() throws -> [String] {
        let started = try activationStartedAt()
        var ids: [String] = []
        try connection.query("SELECT id, entity_kind, kind, parent_notebook_id, end_at, created_at FROM learning_goals ORDER BY id", []) { row in
            guard let id = row.text(0) else { return }
            let kind = row.text(1) ?? LearningGoalEntityKind.kind(kind: row.text(2), parentNotebookID: row.text(3), endAt: row.real(4) ?? 0)
            guard kind == LearningGoalEntityKind.notebook else { return }
            if let started, (row.real(5) ?? 0) > started { return }
            ids.append(id)
        }
        return ids
    }

    func spaceID(teamID: String?) -> String? {
        guard let teamID else { return nil }
        if let named = try? SpaceRows.spaceID(teamID: teamID, connection: connection) { return named }
        return UUID(uuidString: teamID).map { $0.uuidString.lowercased() } ?? teamID
    }

    func excludedPairs(notebookID: String, sources: [String]) throws -> [String: String] {
        let held = try NotebookStateRow.load(notebookID, connection: connection)?.excluded ?? [:]
        guard let store = connection as? KnowledgeStore else {
            return Dictionary(sources.map { ($0, held[$0] ?? NotebookStateRow.pendingPair) }, uniquingKeysWith: { first, _ in first })
        }
        // Before the activation has derived its tables, no Entry has a stamp to name: every untick waits.
        guard let context = try? store.notebookContextEntries(notebookID, row: try NotebookStateRow.load(notebookID, connection: connection)) else {
            return Dictionary(sources.map { ($0, held[$0] ?? NotebookStateRow.pendingPair) }, uniquingKeysWith: { first, _ in first })
        }
        var pairs: [String: String] = [:]
        for source in sources {
            if let pair = held[source], pair != NotebookStateRow.pendingPair { pairs[source] = pair; continue }
            guard let entry = store.comparedEntryID(for: source, in: context) else { continue }
            pairs[source] = ((try? store.entryStampPair(entry, mint: false)) ?? nil) ?? NotebookStateRow.pendingPair
        }
        return pairs
    }
}

// MARK: - The mapping

/// The §10 mapping in Swift (§13.6, R17): an old record becomes the RecordPatches of every v2 record it
/// gives, with whether it owns each and the field hashes the snapshot and the base keep. Each record's
/// fields come from its projection's pure `encodeRows` over the row values the decoded old record
/// gives, so a type's field encoding exists once (R5-m11); `LegacyMappingParityTests` holds it to the
/// activation's derivations. Late import, the refresh and the deferred catch-up apply it (WP16b); the
/// catch-up's snapshot and the seed's base hash with it (WP16a, WP16).
enum LegacyV2Mapping {
    static func map(_ record: LegacyRecord, context: LegacyMappingContext) throws -> LegacyMapping {
        var mapping = LegacyMapping(entity: record.entity, logicalKey: record.logicalKey)
        switch record.payload {
        case .source(let payload):
            try mapSource(payload, record: record, context: context, into: &mapping)
        case .book(let payload):
            mapping.records.append(book(payload))
        case .videoPlaylist(let payload):
            mapping.records.append(videoPlaylist(payload))
            mapping.records.append(followingMark(payload, record: record))
        case .meetingGroup(let payload):
            try mapMeetingGroup(payload, record: record, context: context, into: &mapping)
        case .learningGoal(let payload):
            try mapLearningGoal(payload, record: record, context: context, into: &mapping)
        case .course(let payload):
            try mapCourse(payload, record: record, context: context, into: &mapping)
        case .reviewSession(let payload):
            try mapReviewSession(payload, record: record, context: context, into: &mapping)
        case .artifact(let payload):
            try mapArtifact(payload, record: record, context: context, into: &mapping)
        case .artifactComment(let payload):
            mapping.records.append(try comment(payload, record: record, context: context))
        case .notebookTask(let payload):
            mapping.records.append(try notebookTask(payload, record: record, context: context))
        case .shareRequest(let payload):
            mapping.records.append(try shareRequest(payload, record: record, context: context))
        case .scheduledTask(let payload):
            mapping.records.append(scheduledTask(payload))
        case .scheduledSource(let payload):
            mapping.records.append(try placement(payload, record: record, context: context))
            mapping.records += sourceActivityLogs(payload.activityDays)
        case .memoryItem(let payload):
            mapping.records.append(try memoryItem(payload, context: context))
        case .preference(let payload):
            try mapPreference(payload, context: context, into: &mapping)
        case .idea, .researchDirection, .skill:
            // No Mac projection holds an Idea or a skill Artifact yet, so the activation derives none and
            // neither does the mapping (Corrections, WP15c).
            break
        case .sourceHighlight(let payload):
            mapping.records.append(try highlight(payload, context: context))
        case .memoryAttempt(let payload):
            mapping.records.append(try attemptSitting(payload, context: context))
        case .memoryReviewActivity(let payload):
            if let log = reviewActivity(payload) { mapping.records.append(log) }
        case .walkthroughProgress(let payload):
            if let walk = try walkProgress(payload, context: context) { mapping.records.append(walk) }
        case .team(let payload):
            mapping.records.append(team(payload, context: context))
        case .hiddenSource, .hiddenPodcastShow, .hiddenYouTubeChannel, .hiddenArtifact, .hiddenReviewSession, .dismissedSource,
             .sourceIdea, .videoCitedPaper:
            mapping.records += try mapMarkRecord(record.payload, record: record, context: context)
        case .dropped:
            break
        }
        if let space = context.spaceID(teamID: record.teamID) {
            for index in mapping.records.indices { mapping.records[index].spaceID = space }
        }
        return mapping
    }
}
