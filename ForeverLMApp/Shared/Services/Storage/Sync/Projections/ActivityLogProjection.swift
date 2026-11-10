import Foundation

// MARK: - ActivityLog (docs/cloudkit-schema-design.md §3.5.24)

/// One device's log of one day: per source what was done and for how long, and the review clock.
/// `sources` holds the wire elements as they are (`{kinds, completedKinds, maxFraction, engagedSeconds,
/// notebookIDs, firstAt, lastAt}`), `review` `{seconds, goalSeconds, at}`, and a migrated `legacy22` log
/// the old per-device review rows in `reviewByDevice` (`{activeSeconds, goalSeconds, at}`).
struct DeviceActivityLog: Equatable, Sendable {
    var day: String
    /// The one writer; empty for a log this Mac kept before it knew its device id.
    var deviceID = ""
    var sources: [String: SyncJSON] = [:]
    var review: SyncJSON?
    var reviewByDevice: [String: SyncJSON] = [:]

    /// The wire kind of each local activity kind (`SourceActivityKind`); `walk` has no local kind and is
    /// kept as it came.
    static let wireKinds: [SourceActivityKind: String] = [
        .reading: "read", .listening: "listen", .watching: "watch", .chat: "chat", .review: "review",
    ]

    static func localKind(_ wire: String) -> SourceActivityKind? {
        wireKinds.first { $0.value == wire }?.key
    }

    /// One slice of activity on one source added to the log: kinds and completions unioned, the furthest
    /// fraction kept, the engaged seconds added, the first and last moments widened.
    mutating func add(sourceID: String, kind: SourceActivityKind, completed: Bool, fraction: Double?, engagedSeconds: Double, at: Date) {
        var element = sources[sourceID]?.objectValue ?? [:]
        let wire = Self.wireKinds[kind] ?? kind.rawValue
        func union(_ key: String, _ add: Bool) {
            var names = Set(element[key]?.arrayValue?.compactMap(\.stringValue) ?? [])
            if add { names.insert(wire) }
            element[key] = .array(names.sorted().map(SyncJSON.string))
        }
        union("kinds", true)
        union("completedKinds", completed)
        let ms = SyncTime.milliseconds(at)
        element["maxFraction"] = .number(max(element["maxFraction"]?.numberValue ?? 0, SourceActivityDay.clampFraction(fraction ?? 0)))
        element["engagedSeconds"] = .number(SourceActivityDay.clampSeconds((element["engagedSeconds"]?.numberValue ?? 0) + max(0, engagedSeconds)))
        element["firstAt"] = SyncJSON(min(element["firstAt"]?.int64Value ?? ms, ms))
        element["lastAt"] = SyncJSON(max(element["lastAt"]?.int64Value ?? ms, ms))
        if element["notebookIDs"] == nil { element["notebookIDs"] = .array([]) }
        sources[sourceID] = .object(element)
    }

    /// Two halves of one device's day as one (a day logged before and after its device id was known).
    mutating func merge(_ other: DeviceActivityLog) {
        for (sourceID, theirs) in other.sources {
            guard let mine = sources[sourceID]?.objectValue, let their = theirs.objectValue else {
                sources[sourceID] = theirs
                continue
            }
            sources[sourceID] = .object(Self.fold([mine, their]))
        }
        if let theirs = other.review?.objectValue {
            let mine = review?.objectValue ?? [:]
            review = .object([
                "seconds": .number((mine["seconds"]?.numberValue ?? 0) + (theirs["seconds"]?.numberValue ?? 0)),
                "goalSeconds": theirs["goalSeconds"] ?? mine["goalSeconds"] ?? 0,
                "at": SyncJSON(max(mine["at"]?.int64Value ?? 0, theirs["at"]?.int64Value ?? 0)),
            ])
        }
    }

    /// Elements of one source from several logs as the day's fold (§3.5.24): kinds unioned, engaged seconds
    /// summed, the maximum fraction, the earliest first and latest last moment.
    static func fold(_ elements: [[String: SyncJSON]]) -> [String: SyncJSON] {
        var kinds = Set<String>()
        var completed = Set<String>()
        var notebooks = Set<String>()
        var fraction = 0.0
        var seconds = 0.0
        var first: Int64?
        var last: Int64?
        for element in elements {
            kinds.formUnion(element["kinds"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            completed.formUnion(element["completedKinds"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            notebooks.formUnion(element["notebookIDs"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            fraction = max(fraction, element["maxFraction"]?.numberValue ?? 0)
            seconds += element["engagedSeconds"]?.numberValue ?? 0
            if let at = element["firstAt"]?.int64Value { first = min(first ?? at, at) }
            if let at = element["lastAt"]?.int64Value { last = max(last ?? at, at) }
        }
        var folded: [String: SyncJSON] = [
            "kinds": .array(kinds.sorted().map(SyncJSON.string)),
            "completedKinds": .array(completed.sorted().map(SyncJSON.string)),
            "notebookIDs": .array(notebooks.sorted().map(SyncJSON.string)),
            "maxFraction": .number(fraction),
            "engagedSeconds": .number(SourceActivityDay.clampSeconds(seconds)),
        ]
        if let first { folded["firstAt"] = SyncJSON(first) }
        if let last { folded["lastAt"] = SyncJSON(last) }
        return folded
    }

    /// The elements a record carries: a source is logged only after 30 s of engaged use, unless something
    /// was completed or the activity was not timed (a chat, a review).
    var sentSources: [String: SyncJSON] {
        sources.filter { _, element in
            guard let object = element.objectValue else { return false }
            let kinds = Set(object["kinds"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            let timedOnly = kinds.isSubset(of: ["read", "listen", "watch"])
            let completed = !(object["completedKinds"]?.arrayValue ?? []).isEmpty
            return !timedOnly || completed || (object["engagedSeconds"]?.numberValue ?? 0) >= 30
        }
    }
}

/// The ActivityLog record's projection: this Mac's own logs from `device_activity_days`, and the migrated
/// `legacy22` logs from `activity_logs`, which the seeder and the late importer send. Another device's
/// log is projected into `activity_logs` and never sent back (one writer, §6.1). Under generation 2,
/// `source_activity_days` and `memory_review_activity` are the fold of every log of a day, recomputed
/// when one arrives, so their readers are unchanged.
struct ActivityLogProjection: RecordProjection {
    var recordType: SyncRecordType { .activityLog }

    private static func table(_ name: String) -> ProjectedTable {
        let idSQL: @Sendable (String) -> String = { "'al:' || \($0).day || ':' || \($0).device_id" }
        return ProjectedTable(
            name, localKey: ["day", "device_id"], keyColumns: ["day", "device_id"],
            syncedColumns: name == "activity_logs" ? ["sources_json", "review_json", "review_by_device_json"] : ["sources_json", "review_json"],
            recordTypes: [.activityLog],
            record: { values in
                guard let day = values["day"]?.textValue, let device = values["device_id"]?.textValue, !device.isEmpty else { return nil }
                let id = SyncIdentity.activityLogID(day: day, deviceID: device)
                return RowRecord(type: .activityLog, localID: id, personalID: id)
            },
            localIDSQL: idSQL, personalIDSQL: idSQL
        )
    }

    var tables: [ProjectedTable] { [Self.table("device_activity_days"), Self.table("activity_logs")] }

    var missingRow: MissingRowOutcome { .fields([:]) }
    var missingParentNeverDeletes: Bool { true }
    var priority: OutboxPriority { .personal }
    /// Written debounced every 5 minutes while active (§3.5.24).
    var debounce: TimeInterval { 300 }

    /// The day and device an `al:<day>:<deviceID>` id names.
    static func parts(_ wireID: String) -> (day: String, deviceID: String)? {
        let pieces = wireID.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard pieces.count == 3, pieces[0] == "al", !pieces[1].isEmpty, !pieces[2].isEmpty else { return nil }
        return (pieces[1], pieces[2])
    }

    func loadRows(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws -> DeviceActivityLog? {
        guard let parts = Self.parts(record.wireID) else { return nil }
        if parts.deviceID == SyncIdentity.migratedHistoryDeviceID {
            return try Self.loadLog(table: "activity_logs", day: parts.day, deviceID: parts.deviceID, connection: connection)
        }
        // One writer: only this Mac's own log goes out.
        guard parts.deviceID == (try MemorySyncDevice.current(connection)) else { return nil }
        return try Self.loadLog(table: "device_activity_days", day: parts.day, deviceID: parts.deviceID, connection: connection)
    }

    static func loadLog(table: String, day: String, deviceID: String, connection: SQLiteConnection) throws -> DeviceActivityLog? {
        var log: DeviceActivityLog?
        let byDevice = table == "activity_logs" ? "review_by_device_json" : "'{}'"
        try connection.query(
            "SELECT sources_json, review_json, \(byDevice) FROM \(table) WHERE day = ? AND device_id = ?", [.text(day), .text(deviceID)]
        ) { row in
            log = DeviceActivityLog(
                day: day, deviceID: deviceID, sources: SittingProjection.json(row.text(0))?.objectValue ?? [:],
                review: SittingProjection.json(row.text(1)),
                reviewByDevice: SittingProjection.json(row.text(2))?.objectValue ?? [:]
            )
        }
        return log
    }

    static func encodeRows(_ rows: DeviceActivityLog) -> [String: SyncJSON] {
        var fields: [String: SyncJSON] = ["day": .string(rows.day), "deviceID": .string(rows.deviceID), "sources": .object(rows.sentSources)]
        if let review = rows.review, !review.isNull { fields["review"] = review }
        if !rows.reviewByDevice.isEmpty { fields["reviewByDevice"] = .object(rows.reviewByDevice) }
        return fields
    }

    func apply(_ envelope: SyncEnvelope, to record: ProjectionRecordRef, connection: SQLiteConnection) throws -> ProjectionApplyOutcome {
        guard !record.zone.isSpace, let parts = Self.parts(record.wireID) else { return .projected }
        // This Mac's own log coming back: its rows are the truth.
        if parts.deviceID == (try MemorySyncDevice.current(connection)) { return .projected }
        let fields = envelope.fields
        let held = try Self.loadLog(table: "activity_logs", day: parts.day, deviceID: parts.deviceID, connection: connection)
        let sources = fields["sources"]?.objectValue?.filter { !$0.value.isNull } ?? held?.sources ?? [:]
        let review = fields["review"].map { $0.isNull ? nil : $0 } ?? held?.review
        let byDevice = fields["reviewByDevice"]?.objectValue?.filter { !$0.value.isNull } ?? held?.reviewByDevice ?? [:]
        try connection.execute("""
            INSERT INTO activity_logs (day, device_id, sources_json, review_json, review_by_device_json) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(day, device_id) DO UPDATE SET
                sources_json = excluded.sources_json, review_json = excluded.review_json,
                review_by_device_json = excluded.review_by_device_json
        """, [
            .text(parts.day), .text(parts.deviceID), .text(SittingProjection.text(.object(sources)) ?? "{}"),
            .text(SittingProjection.text(review)), .text(SittingProjection.text(.object(byDevice)) ?? "{}"),
        ])
        guard let store = connection as? KnowledgeStore else { return .projected }
        // The log is the truth and is written; a source it names that this Mac does not hold yet (the
        // phone logged time on one that arrives later, or one deleted here) is left out of the fold, and
        // the record waits for it, so the day is folded again when the Source lands (§5.7).
        let unheld = try store.refoldActivityDay(parts.day)
        return unheld.isEmpty ? .projected : .waiting(unheld.sorted().map { WaitingParent(type: .source, wireID: $0) })
    }

    func applyDeletion(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws {
        // History is append-only (P8): a log the server no longer has stays folded into the day.
    }
}

// MARK: - Logs on this Mac, and the day's fold

extension KnowledgeStore {
    func loadDeviceActivityLog(day: String, deviceID: String) throws -> DeviceActivityLog? {
        try ActivityLogProjection.loadLog(table: "device_activity_days", day: day, deviceID: deviceID, connection: self)
    }

    func saveDeviceActivityLog(_ log: DeviceActivityLog, deviceID: String) throws {
        try execute("""
            INSERT INTO device_activity_days (day, device_id, sources_json, review_json) VALUES (?, ?, ?, ?)
            ON CONFLICT(day, device_id) DO UPDATE SET sources_json = excluded.sources_json, review_json = excluded.review_json
        """, [
            .text(log.day), .text(deviceID), .text(SittingProjection.text(.object(log.sources)) ?? "{}"),
            .text(SittingProjection.text(log.review)),
        ])
    }

    /// A slice of source activity in this Mac's own log (generation 2 only, inside the recorder's
    /// transaction; the log names a source by its wire id, §4.3), beside the `source_activity_days` row the recorder keeps as it always has: that row is
    /// the day's fold, and this log is what other devices fold in.
    func recordOwnSourceActivity(sourceID: String, kind: SourceActivityKind, completed: Bool, fraction: Double?, engagedSeconds: Double, at: Date) throws {
        guard try recordsMemoryForGeneration2() else { return }
        let device = try MemorySyncDevice.current(self) ?? ""
        let day = DayPlan.dateString(for: at)
        var log = try loadDeviceActivityLog(day: day, deviceID: device) ?? DeviceActivityLog(day: day)
        log.add(sourceID: try personalStateSourceKey(sourceID), kind: kind, completed: completed, fraction: fraction, engagedSeconds: engagedSeconds, at: at)
        try saveDeviceActivityLog(log, deviceID: device)
    }

    /// The review clock in this Mac's own log (generation 2 only): this device's row's total, less what
    /// the migrated `legacy22` log already holds for the same old device on that day, so a day that began
    /// under generation 1 is never counted twice by another device's fold.
    func recordOwnReviewActivity(_ activity: MemoryReviewActivity) throws {
        guard try recordsMemoryForGeneration2() else { return }
        let device = try MemorySyncDevice.current(self) ?? ""
        let legacy = try ActivityLogProjection.loadLog(table: "activity_logs", day: activity.day, deviceID: SyncIdentity.migratedHistoryDeviceID, connection: self)
        let baseline = legacy?.reviewByDevice[activity.deviceID]?["activeSeconds"]?.numberValue ?? 0
        var log = try loadDeviceActivityLog(day: activity.day, deviceID: device) ?? DeviceActivityLog(day: activity.day)
        log.review = [
            "seconds": .number(max(0, activity.activeSeconds - baseline)),
            "goalSeconds": .number(activity.goalSeconds),
            "at": SyncJSON(SyncTime.milliseconds(activity.updatedAt)),
        ]
        try saveDeviceActivityLog(log, deviceID: device)
    }

    /// Recomputes a day's `source_activity_days` and `memory_review_activity` rows from every log of the day
    /// (generation 2): the migrated `legacy22` log, this Mac's own and every other device's. Engaged seconds
    /// and review seconds are summed over logs, since each device logs only what it recorded; a source the
    /// logs do not name keeps its row. A source a log names that this Mac does not hold is skipped, never
    /// an error (a throw here would jam the whole inbound page); the keys of those are returned.
    @discardableResult
    func refoldActivityDay(_ day: String) throws -> Set<String> {
        guard let dayStart = DayPlan.startOfDay(day) else { return [] }
        var unheld = Set<String>()
        var logs: [(device: String, log: DeviceActivityLog)] = []
        var devices: [String] = []
        try query("SELECT device_id FROM activity_logs WHERE day = ?", [.text(day)]) { row in
            if let device = row.text(0) { devices.append(device) }
        }
        for device in devices {
            if let log = try ActivityLogProjection.loadLog(table: "activity_logs", day: day, deviceID: device, connection: self) {
                logs.append((device, log))
            }
        }
        var own: [(device: String, log: DeviceActivityLog)] = []
        var ownDevices: [String] = []
        try query("SELECT device_id FROM device_activity_days WHERE day = ?", [.text(day)]) { row in
            if let device = row.text(0) { ownDevices.append(device) }
        }
        for device in ownDevices {
            if let log = try loadDeviceActivityLog(day: day, deviceID: device) { own.append((device, log)) }
        }

        var elements: [String: [[String: SyncJSON]]] = [:]
        for log in logs.map(\.log) + own.map(\.log) {
            for (sourceID, element) in log.sources {
                if let object = element.objectValue { elements[sourceID, default: []].append(object) }
            }
        }
        for (sourceKey, list) in elements.sorted(by: { $0.key < $1.key }) {
            guard let sourceID = try localSourceID(forWireKey: sourceKey) else {
                unheld.insert(sourceKey)
                continue
            }
            let folded = DeviceActivityLog.fold(list)
            let kinds = Set((folded["kinds"]?.arrayValue ?? []).compactMap { $0.stringValue.flatMap(DeviceActivityLog.localKind) })
            let completed = Set((folded["completedKinds"]?.arrayValue ?? []).compactMap { $0.stringValue.flatMap(DeviceActivityLog.localKind) })
            guard !kinds.isEmpty else { continue }
            let first = folded["firstAt"]?.int64Value.map { SyncTime.cocoaSeconds(milliseconds: $0) } ?? dayStart.timeIntervalSinceReferenceDate
            let last = folded["lastAt"]?.int64Value.map { SyncTime.cocoaSeconds(milliseconds: $0) } ?? first
            let placement = try scheduledSourceID(forSource: sourceID) ?? ""
            let id = MemoryTutorIdentity.sourceActivityDayID(
                portableSourceKey: try portableMemorySourceKey(sourceID: sourceID), dayStart: dayStart
            )
            try adoptSourceActivityDayRow(id: id, sourceID: sourceID, dayStart: dayStart.timeIntervalSinceReferenceDate)
            try execute("""
                INSERT INTO source_activity_days (id, scheduled_source_id, source_id, day_start, first_activity_at, last_activity_at,
                    kinds, completed_kinds, max_fraction, engaged_seconds)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(source_id, day_start) DO UPDATE SET
                    scheduled_source_id = CASE WHEN excluded.scheduled_source_id = '' THEN source_activity_days.scheduled_source_id
                                               ELSE excluded.scheduled_source_id END,
                    first_activity_at = excluded.first_activity_at, last_activity_at = excluded.last_activity_at,
                    kinds = excluded.kinds, completed_kinds = excluded.completed_kinds,
                    max_fraction = excluded.max_fraction, engaged_seconds = excluded.engaged_seconds
            """, [
                .text(id), .text(placement), .text(sourceID), .real(dayStart.timeIntervalSinceReferenceDate), .real(first), .real(last),
                .integer(sourceActivityMask(kinds)), .integer(sourceActivityMask(completed)),
                .real(SourceActivityDay.clampFraction(folded["maxFraction"]?.numberValue ?? 0)),
                .real(SourceActivityDay.clampSeconds(folded["engagedSeconds"]?.numberValue ?? 0)),
            ])
        }

        // The review clock: the legacy log's old device rows, and one row per device that logged under
        // generation 2 (`al:<deviceID>`, apart from every old device id). This Mac's own row is its
        // recorder's, as before.
        let mine = try MemorySyncDevice.current(self)
        for (device, log) in logs {
            for (oldDevice, value) in log.reviewByDevice {
                try upsertFoldedReviewActivity(day: day, deviceID: oldDevice, value: value, keepingMaximum: true)
            }
            if let review = log.review, device != mine, device != SyncIdentity.migratedHistoryDeviceID {
                try upsertFoldedReviewActivity(day: day, deviceID: "al:" + device, value: [
                    "activeSeconds": review["seconds"] ?? 0, "goalSeconds": review["goalSeconds"] ?? 0, "at": review["at"] ?? 0,
                ], keepingMaximum: false)
            }
        }
        return unheld
    }

    /// A day's `source_activity_days` id comes from the work's portable key (its DOI or URL), which a team
    /// copy shares with the personal copy, so the copy that was used first that day holds the id under its
    /// own `source_id`. An upsert for the other copy, keyed on `(source_id, day_start)`, then failed the
    /// primary key: the refold threw and the day's ActivityLog was parked as `projectionFailed`. The row
    /// is the work's day, so it becomes this copy's, and the upsert that follows updates it.
    func adoptSourceActivityDayRow(id: String, sourceID: String, dayStart: Double) throws {
        try execute("""
            UPDATE source_activity_days SET source_id = ?1
            WHERE id = ?2 AND source_id <> ?1
              AND NOT EXISTS (SELECT 1 FROM source_activity_days held WHERE held.source_id = ?1 AND held.day_start = ?3)
        """, [.text(sourceID), .text(id), .real(dayStart)])
    }

    private func upsertFoldedReviewActivity(day: String, deviceID: String, value: SyncJSON, keepingMaximum: Bool) throws {
        let active = value["activeSeconds"]?.numberValue ?? 0
        let goal = value["goalSeconds"]?.numberValue ?? 0
        let at = value["at"]?.int64Value.map { SyncTime.cocoaSeconds(milliseconds: $0) } ?? 0
        let activeUpdate = keepingMaximum ? "MAX(memory_review_activity.active_seconds, excluded.active_seconds)" : "excluded.active_seconds"
        try execute("""
            INSERT INTO memory_review_activity (id, day, device_id, active_seconds, goal_seconds, updated_at) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                active_seconds = \(activeUpdate), goal_seconds = excluded.goal_seconds,
                updated_at = MAX(memory_review_activity.updated_at, excluded.updated_at)
        """, [
            .text(MemoryReviewGoal.activityID(day: day, deviceID: deviceID)), .text(day), .text(deviceID),
            .real(active), .real(goal), .real(at),
        ])
    }

    /// The migrated history's logs (§3.5.24): one `al:<day>:legacy22` log per day, its sources from every
    /// `source_activity_days` row of the day (no device column; every device's days are on every Mac, so
    /// each value is already a total) and its review clock from every old device's `memory_review_activity`
    /// row. Rebuilt whole from generation-1 truth, so a second run gives the same logs.
    func deriveLegacyActivityLogs() throws {
        var logs: [String: DeviceActivityLog] = [:]
        var sourceRows: [(sourceID: String, dayStart: Double, first: Double, last: Double, kinds: Int64, completed: Int64, fraction: Double, seconds: Double)] = []
        try query("""
            SELECT COALESCE((SELECT s.wire_key FROM sources s WHERE s.id = source_activity_days.source_id), source_id),
                   day_start, first_activity_at, last_activity_at, kinds, completed_kinds, max_fraction, engaged_seconds
            FROM source_activity_days ORDER BY day_start, source_id
        """, []) { row in
            guard let sourceID = row.text(0) else { return }
            sourceRows.append((sourceID, row.real(1) ?? 0, row.real(2) ?? 0, row.real(3) ?? 0, row.integer(4) ?? 0,
                               row.integer(5) ?? 0, row.real(6) ?? 0, row.real(7) ?? 0))
        }
        func names(_ mask: Int64) -> [SyncJSON] {
            SourceActivityKind.allCases.enumerated().compactMap { index, kind in
                mask & (Int64(1) << Int64(index)) == 0 ? nil : DeviceActivityLog.wireKinds[kind].map(SyncJSON.string)
            }.sorted { ($0.stringValue ?? "") < ($1.stringValue ?? "") }
        }
        for row in sourceRows {
            let day = DayPlan.dateString(for: Date(timeIntervalSinceReferenceDate: row.dayStart))
            var element: [String: SyncJSON] = [
                "kinds": .array(names(row.kinds)), "completedKinds": .array(names(row.completed)), "notebookIDs": .array([]),
                "maxFraction": .number(row.fraction), "engagedSeconds": .number(row.seconds),
                "firstAt": SyncJSON(SyncTime.milliseconds(cocoaSeconds: row.first)), "lastAt": SyncJSON(SyncTime.milliseconds(cocoaSeconds: row.last)),
            ]
            if let held = logs[day]?.sources[row.sourceID]?.objectValue {
                // A duplicate source row of the same day: the larger values stand, as generation 1 merges them.
                element["maxFraction"] = .number(max(row.fraction, held["maxFraction"]?.numberValue ?? 0))
                element["engagedSeconds"] = .number(max(row.seconds, held["engagedSeconds"]?.numberValue ?? 0))
            }
            logs[day, default: DeviceActivityLog(day: day)].sources[row.sourceID] = .object(element)
        }
        try query("SELECT day, device_id, active_seconds, goal_seconds, updated_at FROM memory_review_activity ORDER BY day, device_id", []) { row in
            guard let day = row.text(0), let device = row.text(1), !device.hasPrefix("al:") else { return }
            logs[day, default: DeviceActivityLog(day: day)].reviewByDevice[device] = [
                "activeSeconds": .number(row.real(2) ?? 0), "goalSeconds": .number(row.real(3) ?? 0),
                "at": SyncJSON(SyncTime.milliseconds(cocoaSeconds: row.real(4) ?? 0)),
            ]
        }
        for (day, log) in logs.sorted(by: { $0.key < $1.key }) {
            try execute("""
                INSERT INTO activity_logs (day, device_id, sources_json, review_json, review_by_device_json) VALUES (?, ?, ?, NULL, ?)
                ON CONFLICT(day, device_id) DO UPDATE SET
                    sources_json = excluded.sources_json, review_by_device_json = excluded.review_by_device_json
            """, [
                .text(day), .text(SyncIdentity.migratedHistoryDeviceID), .text(SittingProjection.text(.object(log.sources)) ?? "{}"),
                .text(SittingProjection.text(.object(log.reviewByDevice)) ?? "{}"),
            ])
        }
    }
}
