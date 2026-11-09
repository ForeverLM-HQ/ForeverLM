import Foundation

// MARK: - The Reader's accessors under generation 2 (docs/cloudkit-schema-design.md §3.5.18, §12.7 v160)

/// Under generation 2 a source's position, read mark, review depth and consumed mark live only in its
/// `reading_states` row, on its wire id; under generation 1 the `sources` columns stay their only truth
/// and nothing here runs (D40: no dual write; the activation derives the rows at T0).
extension KnowledgeStore {
    /// The id a source's per-member rows are keyed by under generation 2: its wire id (a team copy's
    /// is its personal copy's id), or the id itself for a source this store does not hold.
    func readingStateKey(sourceID: String) throws -> String {
        try scalarText("SELECT wire_key FROM sources WHERE id = ?", [.text(sourceID)]) ?? sourceID
    }

    /// The source's reading state row, or nil when it has none.
    func loadReadingState(sourceID: String) throws -> ReadingStateRow? {
        try ReadingStateRow.load(try readingStateKey(sourceID: sourceID), connection: self)
    }

    /// Changes one source's reading state. Writes only when something changed and never makes a row
    /// that says nothing, so opening a source, or saving the position it already has, writes nothing
    /// (P9). Returns the row as it now is.
    @discardableResult
    func updateReadingState(sourceID: String, _ change: (inout ReadingStateRow) -> Void) throws -> ReadingStateRow {
        let key = try readingStateKey(sourceID: sourceID)
        let held = try ReadingStateRow.load(key, connection: self)
        var row = held ?? ReadingStateRow(wireID: key)
        change(&row)
        guard row != held, held != nil || !row.isEmpty else { return row }
        try row.save(self)
        return row
    }

    /// A new place in the source: the page or the reader's own locator, with the furthest fraction it
    /// reaches (only ever rising within an epoch) and the time it moved.
    func writeReadingPlace(sourceID: String, page: Int?? = nil, macLocator: String?? = nil, readAt: Date?? = nil, at date: Date = Date()) throws {
        try updateReadingState(sourceID: sourceID) { row in
            let before = row
            if let page {
                row.position = page.map(Int64.init)
                // A PDF Locator is re-derived from the page; another kind stays the reader's.
                if row.locator?["t"]?.stringValue == "pdf" { row.locator = nil }
            }
            if let macLocator {
                row.locator = macLocator.map(ReadingLocatorCodec.wire(macLocator:))
                if let fraction = ReadingLocatorCodec.fraction(macLocator: macLocator), fraction > (row.furthest ?? 0) {
                    row.furthest = fraction
                    row.furthestEpoch = row.furthestEpoch ?? 0
                }
            }
            if let readAt { row.readAt = readAt?.timeIntervalSinceReferenceDate }
            if row.position != before.position || row.locator != before.locator {
                row.lastReadAt = max(row.lastReadAt ?? 0, date.timeIntervalSinceReferenceDate)
            }
        }
    }

    /// "Mark unread", and a video's Mark as Not Watched: the furthest pair starts a new epoch at 0, so
    /// the reset beats every older maximum on every device (§3.5.18).
    func resetReadingProgress(_ row: inout ReadingStateRow) {
        guard row.furthest != nil || row.furthestEpoch != nil else { return }
        row.furthestEpoch = (row.furthestEpoch ?? 0) + 1
        row.furthest = 0
    }

    /// The Mac reader's locator string a source's reading state holds now.
    func readingMacLocator(sourceID: String) throws -> String? {
        ReadingLocatorCodec.macLocator(wire: try loadReadingState(sourceID: sourceID)?.locator)
    }

    /// Marks a source read at `date` when it is not read yet (a finished Schedule item, a review).
    /// Returns whether it wrote.
    @discardableResult
    func fillReadingStateReadAt(sourceID: String, at date: Date) throws -> Bool {
        let row = try loadReadingState(sourceID: sourceID)
        guard row?.readAt == nil else { return false }
        try updateReadingState(sourceID: sourceID) { $0.readAt = date.timeIntervalSinceReferenceDate }
        return true
    }

    /// A notebook item's completion is its source's (§10): the first completion stands.
    func fillReadingStateCompletedAt(sourceID: String, at date: Date) throws {
        try updateReadingState(sourceID: sourceID) { row in
            if row.completedAt == nil { row.completedAt = date.timeIntervalSinceReferenceDate }
        }
    }

    /// A new source's reading values from the model it was saved from (an import that knows the
    /// learner read it): each fills a value the state does not hold, so a re-imported source keeps
    /// the state it had.
    func seedReadingState(sourceID: String, page: Int?, macLocator: String?, readAt: Date?) throws {
        guard page != nil || macLocator != nil || readAt != nil else { return }
        try updateReadingState(sourceID: sourceID) { row in
            if row.position == nil, let page { row.position = Int64(page) }
            if row.locator == nil, let macLocator { row.locator = ReadingLocatorCodec.wire(macLocator: macLocator) }
            if row.readAt == nil, let readAt { row.readAt = readAt.timeIntervalSinceReferenceDate }
        }
    }

    /// The sources the learner has been into by their reading state: read or consumed.
    func readOrConsumedSourceIDs() throws -> [String] {
        var ids: [String] = []
        try query("""
            SELECT s.id FROM sources s JOIN reading_states rs ON rs.wire_id = s.wire_key
            WHERE rs.read_at IS NOT NULL OR rs.consumed_at IS NOT NULL
        """, []) { row in if let id = row.text(0) { ids.append(id) } }
        return ids
    }

    /// The review depths of these sources from their reading states, by the caller's ids.
    func readingStateReviewDepths(sourceIDs: [String]) throws -> [String: String] {
        guard !sourceIDs.isEmpty else { return [:] }
        var result: [String: String] = [:]
        let placeholders = Array(repeating: "?", count: sourceIDs.count).joined(separator: ", ")
        try query("""
            SELECT s.id, rs.review_depth FROM sources s JOIN reading_states rs ON rs.wire_id = s.wire_key
            WHERE s.id IN (\(placeholders)) AND rs.review_depth IS NOT NULL
        """, sourceIDs.map { .text($0) }) { row in
            if let id = row.text(0), let depth = row.text(1) { result[id] = depth }
        }
        return result
    }

    /// A per-member key for a walk or an Understanding document: a source's wire id (an animation's
    /// id stays its own).
    func perMemberKey(_ subjectID: String) throws -> String {
        try readingStateKey(sourceID: subjectID)
    }
}

// MARK: - The narration's resume point (`ReadingState.listen`)

/// Today's `ArticleSpeechPlaybackPosition` whole as `ReadingState.listen` (§3.5.18): `{globalTime,
/// appleCharacterOffset?, contentSignature?, at}`, the seconds into the narration, the character offset
/// Apple's voices resume from, the signature of the text it was made on, and when it was saved.
enum ListenPositionCodec {
    static func wire(_ position: ArticleSpeechPlaybackPosition) -> SyncJSON {
        var object: [String: SyncJSON] = [
            "globalTime": .number(position.globalTime), "at": SyncJSON(SyncTime.milliseconds(position.updatedAt)),
        ]
        if let offset = position.appleCharacterOffset { object["appleCharacterOffset"] = SyncJSON(offset) }
        if let signature = position.contentSignature { object["contentSignature"] = .string(signature) }
        return .object(object)
    }

    static func position(_ wire: SyncJSON?) -> ArticleSpeechPlaybackPosition? {
        guard let object = wire?.objectValue, let time = object["globalTime"]?.numberValue, time.isFinite else { return nil }
        return ArticleSpeechPlaybackPosition(
            globalTime: time,
            appleCharacterOffset: object["appleCharacterOffset"]?.intValue,
            contentSignature: object["contentSignature"]?.stringValue,
            updatedAt: object["at"]?.int64Value.map(SyncTime.date(milliseconds:)) ?? .distantPast
        )
    }
}

extension KnowledgeStore {
    /// The narration's resume point under generation 2; nil under generation 1, where it is the
    /// `listen.position.*` row.
    func loadListenPosition(sourceID: String) throws -> ArticleSpeechPlaybackPosition? {
        return ListenPositionCodec.position(try loadReadingState(sourceID: sourceID)?.listen)
    }

    /// Saves (or, with nil, forgets) the narration's resume point under generation 2. An older save
    /// arriving late never replaces a newer one, as `ListeningPositionSync.newest` decides today.
    func saveListenPosition(_ position: ArticleSpeechPlaybackPosition?, sourceID: String) throws {
        try updateReadingState(sourceID: sourceID) { row in
            guard let position else {
                row.listen = nil
                return
            }
            let held = ListenPositionCodec.position(row.listen)
            guard ListeningPositionSync.newest(held, position) == position else { return }
            row.listen = ListenPositionCodec.wire(position)
        }
    }
}
