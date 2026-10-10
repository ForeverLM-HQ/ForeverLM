import Foundation

// The Schedule on the phone under generation 2 (docs/cloudkit-schema-design.md §3.5.18, §3.5.21, §3.5.24,
// §10; §14.2 WP20c): one Placement per source (`pl:<sourceID>`) in the member's `Library`, written as the
// web's generation-2 writer writes it (`library-mutations-v2.js`) and read in the shape the Mac's
// `PlacementProjection` (WP12b) reads, and the activity days the Schedule shows folded from every device's
// ActivityLog. A placement is never deleted: taken off the Schedule its state flips to `removed`. A
// completion is the placement's `completedAt` and the source's `ReadingState.completedAt`, which is what a
// notebook's or a Goal's item completion became (§10).

/// A placement's day and order as the wire names them: a calendar day in the learner's time zone, and the
/// fractional key of the order within it, the n-th key for n seconds past midnight (the Mac's
/// `PlacementDay` and `SourceOrderKeys`), so a key the phone writes reads back as the same order on a Mac.
enum MobilePlacementDay {
    /// The keys of the first orders, made once; an order past them is made when asked.
    private static let precomputed: [String] = (try? FractionalIndex.keys(between: nil, and: nil, count: 4_096)) ?? []
    private static let offsets: [String: Int] = Dictionary(precomputed.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })

    /// The same day an ActivityLog is named by.
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        MemoryReviewGoal.dayKey(for: date, calendar: calendar)
    }

    /// The local midnight of a `YYYY-MM-DD` day.
    static func start(of day: String, calendar: Calendar = .current) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        return calendar.startOfDay(for: date)
    }

    static func orderKey(_ order: Int) -> String? {
        let order = min(max(order, 0), 86_399)
        if order < precomputed.count { return precomputed[order] }
        return try? FractionalIndex.keys(between: nil, and: nil, count: order + 1).last
    }

    static func order(ofKey key: String?) -> Int? {
        key.flatMap { offsets[$0] }
    }

    /// When generation 1 planned the row: the day's midnight plus its order in seconds.
    static func plannedAt(day: String, orderKey: String?, calendar: Calendar = .current) -> Date? {
        start(of: day, calendar: calendar).map { $0.addingTimeInterval(Double(order(ofKey: orderKey) ?? 0)) }
    }
}

// MARK: - Reading the Schedule

extension MobileReadModels {
    /// The member's live placements in the shape generation 1's rows have, each with its source's activity
    /// days (folded here unless the caller already holds them), ordered by when they are planned.
    static func placements(in connection: SQLiteConnection, sourceID: String? = nil,
                           activityDays held: [String: [SourceActivityDay]]? = nil) throws -> [MobileCloudScheduledSource] {
        let days = try held ?? activityDays(in: connection)
        var placements: [MobileCloudScheduledSource] = []
        try connection.query("""
            SELECT id, source_id, day, order_key, origin, goals_json, completed_at, edited_at FROM m_placements
            WHERE zone_key = ? AND state = 'active' AND (? IS NULL OR source_id = ?)
        """, [.text(libraryKey), .text(sourceID), .text(sourceID)]) { row in
            guard let id = row.text(0), let day = row.text(2), let plannedAt = MobilePlacementDay.plannedAt(day: day, orderKey: row.text(3)) else { return }
            let source = row.text(1) ?? String(id.dropFirst(3))
            placements.append(MobileCloudScheduledSource(
                id: id, sourceID: source, sourceIdentity: nil, plannedAt: plannedAt, completedAt: date(row.integer(6)),
                goalIDs: members(row.text(5)), updatedAt: date(row.integer(7)) ?? plannedAt, activityDays: days[source] ?? [],
                isAutomatic: row.text(4) == "automatic"
            ))
        }
        return placements.sorted { $0.plannedAt != $1.plannedAt ? $0.plannedAt < $1.plannedAt : $0.id < $1.id }
    }

    /// Every source's activity days, folded from the ActivityLogs of every device (§3.5.24) as the web
    /// folds them: one day per source, kinds unioned, the deepest point, the seconds of each device added.
    static func activityDays(in connection: SQLiteConnection) throws -> [String: [SourceActivityDay]] {
        var folded: [String: [String: SourceActivityDay]] = [:]
        try connection.query("SELECT day, sources_json FROM m_activity_logs WHERE zone_key = ? AND sources_json IS NOT NULL ORDER BY day, id",
                             [.text(libraryKey)]) { row in
            guard let day = row.text(0), let start = MobilePlacementDay.start(of: day),
                  let sources = row.text(1).flatMap({ try? SyncJSON(parsing: Data($0.utf8)) })?.objectValue else { return }
            for (sourceID, element) in sources {
                guard let element = element.objectValue else { continue }
                func kinds(_ key: String) -> Set<SourceActivityKind> {
                    Set((element[key]?.arrayValue ?? []).compactMap { $0.stringValue.flatMap(activityKind) })
                }
                let first = date(element["firstAt"]?.int64Value) ?? start
                let last = date(element["lastAt"]?.int64Value) ?? first
                let fraction = min(max(element["maxFraction"]?.numberValue ?? 0, 0), 1)
                let seconds = max(element["engagedSeconds"]?.numberValue ?? 0, 0)
                if var held = folded[sourceID]?[day] {
                    held.firstActivityAt = min(held.firstActivityAt, first)
                    held.lastActivityAt = max(held.lastActivityAt, last)
                    held.kinds.formUnion(kinds("kinds"))
                    held.completedKinds.formUnion(kinds("completedKinds"))
                    held.maxFraction = max(held.maxFraction, fraction)
                    held.engagedSeconds += seconds
                    folded[sourceID]?[day] = held
                } else {
                    folded[sourceID, default: [:]][day] = SourceActivityDay(
                        id: "\(day):\(sourceID)", sourceID: sourceID, dayStart: start, firstActivityAt: first, lastActivityAt: last,
                        kinds: kinds("kinds"), completedKinds: kinds("completedKinds"), maxFraction: fraction, engagedSeconds: seconds
                    )
                }
            }
        }
        return folded.mapValues { $0.values.sorted { $0.dayStart < $1.dayStart } }
    }

    /// An ActivityLog's kind word as generation 1 names it (`read` is `reading`).
    static func activityKind(_ wire: String) -> SourceActivityKind? {
        switch wire {
        case "read": return .reading
        case "listen": return .listening
        case "watch": return .watching
        default: return SourceActivityKind(rawValue: wire)
        }
    }

    /// The notebooks and Goals a placement can be tagged with, as the Schedule names and filters them.
    static func scheduleGoals(in connection: SQLiteConnection) throws -> [MobileCloudGoal] {
        var goals: [MobileCloudGoal] = []
        for (table, kind, edited) in [("m_notebooks", "companion", "edited_at"), ("m_goals", "goal", "due_at")] {
            try connection.query("SELECT id, title, status, \(edited) FROM \(table) ORDER BY id", []) { row in
                guard let id = row.text(0) else { return }
                goals.append(MobileCloudGoal(id: id, title: row.text(1) ?? "", status: row.text(2) ?? "active", kind: kind, parentNotebookID: nil,
                                             updatedAt: date(row.integer(3)) ?? .distantPast))
            }
        }
        return goals
    }
}

// MARK: - Writing the Schedule

extension MobileWrite {
    func heldPlacement(_ sourceID: String) throws -> SyncEnvelope? {
        try held(.placement, SyncIdentity.placementID(sourceID: sourceID), in: Self.libraryKey)
    }

    /// The live placement of a source as the Schedule shows it, after a write.
    func scheduledSource(_ sourceID: String) throws -> MobileCloudScheduledSource? {
        try MobileReadModels.placements(in: connection, sourceID: sourceID).first
    }

    /// Puts a source on a day (the web's `scheduleSource`): active, on that day at `order`, deliberately
    /// placed (tagged `goal` when it serves a notebook or Goal, else `manual`), with that tag added.
    mutating func schedule(_ sourceID: String, on date: Date, order: Int, goalID: String?) throws {
        let goal = goalID.flatMap { $0.isEmpty ? nil : ((try? resolvedNotebook($0))?.id ?? $0) }
        var patch = placementPatch(sourceID)
        patch.changes["state"] = .value(.string("active"))
        patch.changes["day"] = .value(.string(MobilePlacementDay.day(date)))
        if let key = MobilePlacementDay.orderKey(order) { patch.changes["orderKey"] = .value(.string(key)) }
        patch.changes["origin"] = .value(.string(goal == nil ? "manual" : "goal"))
        if let goal { patch.changes["goalIDs"] = .elements([goal: .bool(true)]) }
        if try heldPlacement(sourceID) == nil { patch.changes["addedAt"] = .value(SyncJSON(milliseconds)) }
        try write(patch, in: Self.libraryKey)
    }

    /// Opens a completed placement again, and the source's completion with it (§10).
    mutating func reopenPlacement(_ sourceID: String) throws {
        guard try heldPlacement(sourceID) != nil else { throw MobileRecordWriterError.refused("This Schedule item is no longer available.") }
        var patch = placementPatch(sourceID)
        patch.changes["completedAt"] = .value(.null)
        try write(patch, in: Self.libraryKey)
        if try heldCompletion(sourceID) != nil {
            var reading = readingPatch(sourceID)
            reading.changes["completedAt"] = .value(.null)
            try write(reading, in: Self.libraryKey)
        }
    }

    /// Takes tags off a placement (all of them when `goalIDs` is nil). One left with no tag stays on the
    /// Schedule as the automatic entry on the source's latest activity day when it has activity, else its
    /// state is `removed` (generation 1's release, the web's `releasePlacement`).
    mutating func releasePlacement(_ sourceID: String, goalIDs: [String]?) throws {
        guard let held = try heldPlacement(sourceID) else { return }
        let tagged = members(held.fields["goalIDs"])
        let removing = goalIDs.map { ids in tagged.filter(ids.contains) } ?? tagged
        var patch = placementPatch(sourceID)
        if !removing.isEmpty { patch.changes["goalIDs"] = .elements(Dictionary(uniqueKeysWithValues: removing.map { ($0, SyncJSON.bool(false)) })) }
        if tagged.allSatisfy(removing.contains) {
            if let day = try latestActivityDay(sourceID) {
                patch.changes["origin"] = .value(.string("automatic"))
                patch.changes["day"] = .value(.string(day))
            } else {
                patch.changes["state"] = .value(.string("removed"))
            }
        }
        try write(patch, in: Self.libraryKey)
    }

    /// Marks a source's live placement done, and the source completed and read once (the web's
    /// `completeScheduledSource`). A source not on the Schedule is left alone.
    mutating func completePlacement(_ sourceID: String, at date: Date) throws {
        guard let held = try heldPlacement(sourceID), held.fields["state"]?.stringValue != "removed" else { return }
        if held.fields["completedAt"].map({ $0 == .null }) ?? true {
            var patch = placementPatch(sourceID)
            patch.changes["completedAt"] = .value(SyncJSON(SyncTime.milliseconds(date)))
            try write(patch, in: Self.libraryKey)
        }
        try markCompleted(sourceID, at: date)
    }

    /// Activity the device logged on a source (§3.5.24) puts it on the Schedule: a source with no live
    /// placement gets an automatic one on that day, and an automatic one follows the learner to the day
    /// of the activity. A deliberate placement keeps its day.
    mutating func placeAutomatically(_ sourceID: String, at date: Date, order: Int) throws {
        let held = try heldPlacement(sourceID)
        let live = held.map { $0.fields["state"]?.stringValue != "removed" } ?? false
        let day = MobilePlacementDay.day(date)
        var patch = placementPatch(sourceID)
        if !live {
            patch.changes["state"] = .value(.string("active"))
            patch.changes["origin"] = .value(.string("automatic"))
            if held == nil { patch.changes["addedAt"] = .value(SyncJSON(SyncTime.milliseconds(date))) }
        } else if held?.fields["origin"]?.stringValue != "automatic" || held?.fields["day"]?.stringValue == day {
            return
        }
        patch.changes["day"] = .value(.string(day))
        if let key = MobilePlacementDay.orderKey(order) { patch.changes["orderKey"] = .value(.string(key)) }
        try write(patch, in: Self.libraryKey)
    }

    /// Work finished (a podcast heard, a paper read to the end): its placement on that day, made automatic
    /// when the source had none, completed, and the source completed (the web's `recordSourceConsumption`).
    mutating func consumePlacement(_ sourceID: String, at date: Date, order: Int) throws {
        try placeAutomatically(sourceID, at: date, order: order)
        try completePlacement(sourceID, at: date)
    }

    /// The latest day any device logged activity on the source, from the ActivityLogs' sources.
    func latestActivityDay(_ sourceID: String) throws -> String? {
        try connection.scalarText("""
            SELECT MAX(day) FROM m_activity_logs WHERE zone_key = ? AND sources_json IS NOT NULL
              AND EXISTS (SELECT 1 FROM json_each(m_activity_logs.sources_json) WHERE json_each.key = ? AND json_each.type = 'object')
        """, [.text(Self.libraryKey), .text(sourceID)])
    }

    /// Completed and read, once each (the web's `markCompleted`).
    private mutating func markCompleted(_ sourceID: String, at date: Date) throws {
        let state = try held(.readingState, SyncIdentity.readingStateID(targetID: sourceID), in: Self.libraryKey)
        var patch = readingPatch(sourceID)
        let at = SyncJSON(SyncTime.milliseconds(date))
        if state?.fields["completedAt"].map({ $0 == .null }) ?? true { patch.changes["completedAt"] = .value(at) }
        if state?.fields["readAt"].map({ $0 == .null }) ?? true { patch.changes["readAt"] = .value(at) }
        guard patch.changes.count > 2 else { return }
        try write(patch, in: Self.libraryKey)
    }

    private func heldCompletion(_ sourceID: String) throws -> SyncJSON? {
        guard let value = try held(.readingState, SyncIdentity.readingStateID(targetID: sourceID), in: Self.libraryKey)?.fields["completedAt"],
              value != .null else { return nil }
        return value
    }

    private func placementPatch(_ sourceID: String) -> RecordPatch {
        var patch = RecordPatch(.placement, id: SyncIdentity.placementID(sourceID: sourceID))
        patch.changes["sourceID"] = .value(.string(sourceID))
        return patch
    }

    private func readingPatch(_ sourceID: String) -> RecordPatch {
        var patch = RecordPatch(.readingState, id: SyncIdentity.readingStateID(targetID: sourceID))
        patch.changes["targetKind"] = .value(.string("source"))
        patch.changes["targetID"] = .value(.string(sourceID))
        return patch
    }
}
