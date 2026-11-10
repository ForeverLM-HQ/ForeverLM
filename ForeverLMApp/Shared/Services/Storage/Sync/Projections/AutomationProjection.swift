import Foundation

// MARK: - A scheduled task as an Automation (§3.5.29)

/// A scheduled task's cadence as the Automation's `schedule.rrule` (RFC 5545), the twin of the web's
/// `scheduledTaskRule` and `scheduledTaskCadenceOfRule` (`library-scheduled-tasks.js`):
/// `FREQ=DAILY;BYHOUR=h;BYMINUTE=m`, `FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;…` for weekdays,
/// `FREQ=WEEKLY;BYDAY=<SU…SA>;…`, `FREQ=MONTHLY;BYMONTHDAY=d;…`, and once as
/// `FREQ=DAILY;COUNT=1;DTSTART=<yyyymmdd>;…`, its day in the task's zone.
enum AutomationSchedule {
    static let ruleDays = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]

    struct Parts: Equatable, Sendable {
        var cadence: ScheduledTaskCadence
        var weekday: Int?
        var dayOfMonth: Int?
        var hour: Int
        var minute: Int
        /// For `once`, local midnight of the rule's day in the task's zone; nil for every other cadence.
        var startDate: Date?
    }

    static func zone(_ identifier: String?) -> TimeZone {
        identifier.flatMap(TimeZone.init(identifier:)) ?? .current
    }

    private static func bounded(_ value: Int?, _ fallback: Int, _ low: Int, _ high: Int) -> Int {
        value.map { min(max($0, low), high) } ?? fallback
    }

    static func rule(cadence: ScheduledTaskCadence, weekday: Int?, dayOfMonth: Int?, hour: Int, minute: Int,
                     startDate: Date?, createdAt: Date, timeZoneID: String?) -> String {
        let time = "BYHOUR=\(hour);BYMINUTE=\(minute)"
        switch cadence {
        case .once:
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone(timeZoneID)
            let day = calendar.dateComponents([.year, .month, .day], from: startDate ?? createdAt)
            let stamp = String(format: "%04d%02d%02d", day.year ?? 1970, day.month ?? 1, day.day ?? 1)
            return "FREQ=DAILY;COUNT=1;DTSTART=\(stamp);\(time)"
        case .weekdays:
            return "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;\(time)"
        case .weekly:
            return "FREQ=WEEKLY;BYDAY=\(ruleDays[bounded(weekday, 2, 1, 7) - 1]);\(time)"
        case .monthly:
            return "FREQ=MONTHLY;BYMONTHDAY=\(bounded(dayOfMonth, 1, 1, 31));\(time)"
        case .daily:
            return "FREQ=DAILY;\(time)"
        }
    }

    static func parts(ofRule rrule: String?, timeZoneID: String?) -> Parts {
        var rule: [String: String] = [:]
        for part in (rrule ?? "").split(separator: ";") {
            let pair = part.split(separator: "=", omittingEmptySubsequences: false)
            if pair.count == 2 { rule[String(pair[0])] = String(pair[1]) }
        }
        let days = (rule["BYDAY"] ?? "").split(separator: ",").map(String.init)
        let cadence: ScheduledTaskCadence
        if rule["COUNT"] == "1" {
            cadence = .once
        } else if rule["FREQ"] == "MONTHLY" {
            cadence = .monthly
        } else if rule["FREQ"] == "WEEKLY" {
            cadence = days == Array(ruleDays[1...5]) ? .weekdays : .weekly
        } else {
            cadence = .daily
        }
        var startDate: Date?
        if let start = rule["DTSTART"], start.count >= 8,
           let year = Int(start.prefix(4)), let month = Int(start.dropFirst(4).prefix(2)), let day = Int(start.dropFirst(6).prefix(2)) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone(timeZoneID)
            startDate = calendar.date(from: DateComponents(year: year, month: month, day: day))
        }
        let weekday = days.first.flatMap { ruleDays.firstIndex(of: $0) }.map { $0 + 1 }
        return Parts(
            cadence: cadence,
            weekday: cadence == .weekly ? weekday : nil,
            dayOfMonth: cadence == .monthly ? bounded(rule["BYMONTHDAY"].flatMap { Int($0) }, 1, 1, 31) : nil,
            hour: bounded(rule["BYHOUR"].flatMap { Int($0) }, 8, 0, 23),
            minute: bounded(rule["BYMINUTE"].flatMap { Int($0) }, 0, 0, 59),
            startDate: startDate
        )
    }
}

/// An Automation's runs as a fixed ring of 20 slots (`runs`, `slot0`…`slot19`, D42), written only by
/// the Mac that runs it: run n takes `slot(n mod 20)`, so the map never grows. The local truth is
/// `scheduled_task_runs.ring_slot`; generation 1 already keeps the newest 20 receipts
/// (`ScheduledTask.retainedRunCount`), so a ring of 20 holds every retained one.
enum AutomationRing {
    static let size = ScheduledTask.retainedRunCount

    static func key(_ index: Int) -> String { "slot\(((index % size) + size) % size)" }

    static func index(ofKey key: String) -> Int? {
        guard key.hasPrefix("slot"), let index = Int(key.dropFirst(4)), (0..<size).contains(index) else { return nil }
        return index
    }

    /// The slot after the newest other run's: `slot0` for a task's first run.
    static func nextSlot(taskID: String, excluding runID: String, connection: SQLiteConnection) throws -> String {
        var newest: String??
        try connection.query("""
            SELECT ring_slot FROM scheduled_task_runs WHERE task_id = ? AND id <> ? ORDER BY occurrence_at DESC, id DESC LIMIT 1
        """, [.text(taskID), .text(runID)]) { row in newest = .some(row.text(0)) }
        guard let newest else { return key(0) }
        guard let slot = newest.flatMap(index(ofKey:)) else {
            // Runs kept before the ring had slots: the next after however many there are.
            let count = try connection.scalarInteger("SELECT COUNT(*) FROM scheduled_task_runs WHERE task_id = ? AND id <> ?", [.text(taskID), .text(runID)]) ?? 0
            return key(Int(count))
        }
        return key(slot + 1)
    }

    /// The activation's slots: the newest 20 runs, oldest first, take `slot0`…; anything older takes none.
    static func assignSlots(taskID: String, connection: SQLiteConnection) throws {
        var ids: [String] = []
        try connection.query("""
            SELECT id FROM scheduled_task_runs WHERE task_id = ? ORDER BY occurrence_at DESC, id DESC LIMIT ?
        """, [.text(taskID), .integer(Int64(size))]) { row in
            if let id = row.text(0) { ids.append(id) }
        }
        try connection.execute("UPDATE scheduled_task_runs SET ring_slot = NULL WHERE task_id = ? AND ring_slot IS NOT NULL", [.text(taskID)])
        for (index, id) in ids.reversed().enumerated() {
            try connection.execute("UPDATE scheduled_task_runs SET ring_slot = ? WHERE id = ?", [.text(key(index)), .text(id)])
        }
    }
}

/// One scheduled task's rows: the task and its slotted runs.
struct AutomationRows: Equatable, Sendable {
    var id: String
    var title: String
    var instruction: String
    var notebookID: String?
    var cadence: ScheduledTaskCadence
    var weekday: Int?
    var dayOfMonth: Int?
    var hour: Int
    var minute: Int
    var timeZoneID: String?
    var startDate: Double?
    var isEnabled: Bool
    var createdAt: Double
    var runnerDeviceID: String?
    var runs: [Run]

    struct Run: Equatable, Sendable {
        var id: String
        var slot: String
        var occurrenceAt: Double
        var status: String
        var sessionID: String?
        var message: String?
    }
}

/// The Automation record's projection (§3.5.29): private to the member. `scheduled_tasks` and
/// `scheduled_task_runs` stay the local tables; a run is an element of `runs` by its slot. Generation 1's
/// `source_ids` have no Automation field and stay on this Mac, as the web reads them (none); `model`
/// has no column and is left as the record holds it.
struct AutomationProjection: RecordProjection {
    var recordType: SyncRecordType { .automation }

    static let taskColumns = [
        "title", "instruction", "notebook_id", "cadence", "weekday", "day_of_month", "hour", "minute", "time_zone", "start_date",
        "is_enabled", "created_at", "runner_device_id",
    ]
    static let runColumns = ["ring_slot", "occurrence_at", "status", "session_id", "message"]

    var tables: [ProjectedTable] {
        [
            .records("scheduled_tasks", type: .automation, syncedColumns: Self.taskColumns),
            ProjectedTable(
                "scheduled_task_runs", localKey: ["id"], keyColumns: ["task_id"], syncedColumns: Self.runColumns,
                parents: [LocalParent("task_id", references: "scheduled_tasks", type: .automation, role: .container)],
                elementColumn: "ring_slot", recordTypes: [.automation],
                record: { values in values["task_id"]?.textValue.map { RowRecord(type: .automation, localID: $0, personalID: $0) } },
                localIDSQL: { "\($0).task_id" }, personalIDSQL: { "\($0).task_id" }
            ),
        ]
    }

    private static func column(_ names: String...) -> FieldFeed { .columns(table: "scheduled_tasks", names) }

    var feeds: [String: FieldFeed] {
        [
            "title": Self.column("title"), "prompt": Self.column("instruction"),
            "schedule": Self.column("cadence", "weekday", "day_of_month", "hour", "minute", "time_zone", "start_date"),
            "notebookID": Self.column("notebook_id"), "enabled": Self.column("is_enabled"),
            "runnerDeviceID": Self.column("runner_device_id"), "createdAt": Self.column("created_at"),
            "runs": .elementRows(table: "scheduled_task_runs"),
        ]
    }

    var missingRow: MissingRowOutcome { .delete }
    var priority: OutboxPriority { .personal }

    func loadRows(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws -> AutomationRows? {
        var rows: AutomationRows?
        try connection.query("""
            SELECT title, instruction, notebook_id, cadence, weekday, day_of_month, hour, minute, time_zone, start_date, is_enabled,
                   created_at, runner_device_id
            FROM scheduled_tasks WHERE id = ?
        """, [.text(record.localID)]) { row in
            rows = AutomationRows(
                id: record.localID, title: row.text(0) ?? "", instruction: row.text(1) ?? "", notebookID: row.text(2),
                cadence: ScheduledTaskCadence(rawValue: row.text(3) ?? "") ?? .daily, weekday: row.integer(4).map(Int.init),
                dayOfMonth: row.integer(5).map(Int.init), hour: Int(row.integer(6) ?? 8), minute: Int(row.integer(7) ?? 0),
                timeZoneID: row.text(8), startDate: row.real(9), isEnabled: (row.integer(10) ?? 1) != 0, createdAt: row.real(11) ?? 0,
                runnerDeviceID: row.text(12), runs: []
            )
        }
        guard var found = rows else { return nil }
        try connection.query("""
            SELECT id, ring_slot, occurrence_at, status, session_id, message FROM scheduled_task_runs
            WHERE task_id = ? AND ring_slot IS NOT NULL ORDER BY occurrence_at, id
        """, [.text(record.localID)]) { row in
            guard let id = row.text(0), let slot = row.text(1) else { return }
            found.runs.append(AutomationRows.Run(
                id: id, slot: slot, occurrenceAt: row.real(2) ?? 0, status: row.text(3) ?? "failed", sessionID: row.text(4), message: row.text(5)
            ))
        }
        return found
    }

    static func encodeRows(_ rows: AutomationRows) -> [String: SyncJSON] {
        let rule = AutomationSchedule.rule(
            cadence: rows.cadence, weekday: rows.weekday, dayOfMonth: rows.dayOfMonth, hour: rows.hour, minute: rows.minute,
            startDate: rows.startDate.map(Date.init(timeIntervalSinceReferenceDate:)),
            createdAt: Date(timeIntervalSinceReferenceDate: rows.createdAt), timeZoneID: rows.timeZoneID
        )
        var schedule: [String: SyncJSON] = ["rrule": .string(rule)]
        if let zone = rows.timeZoneID { schedule["timezone"] = .string(zone) }
        var runs: [String: SyncJSON] = [:]
        for run in rows.runs {
            var slot: [String: SyncJSON] = [
                "runID": .string(run.id), "at": SyncJSON(SyncTime.milliseconds(cocoaSeconds: run.occurrenceAt)), "status": .string(run.status),
            ]
            if let session = run.sessionID { slot["outputRef"] = .string(ItemRef(.chat, session).rawValue) }
            if let message = run.message, !message.isEmpty { slot["message"] = .string(message) }
            runs[run.slot] = .object(slot)
        }
        return [
            "title": .string(rows.title),
            "prompt": .string(rows.instruction),
            "schedule": .object(schedule),
            "notebookID": rows.notebookID.map(SyncJSON.string) ?? .null,
            "enabled": .bool(rows.isEnabled),
            "runnerDeviceID": rows.runnerDeviceID.map(SyncJSON.string) ?? .null,
            "runs": .object(runs),
            "createdAt": SyncJSON(SyncTime.milliseconds(cocoaSeconds: rows.createdAt)),
        ]
    }

    func apply(_ envelope: SyncEnvelope, to record: ProjectionRecordRef, connection: SQLiteConnection) throws -> ProjectionApplyOutcome {
        guard !record.zone.isSpace else { return .projected }
        let fields = envelope.fields
        let id = record.localID
        let now = Date().timeIntervalSinceReferenceDate
        var rows = try loadRows(record, connection: connection) ?? AutomationRows(
            id: id, title: "", instruction: "", cadence: .daily, hour: 8, minute: 0, isEnabled: true, createdAt: now, runs: []
        )
        if let title = fields["title"]?.stringValue { rows.title = title }
        if let prompt = fields["prompt"]?.stringValue { rows.instruction = prompt }
        if let notebook = fields["notebookID"] { rows.notebookID = notebook.stringValue }
        if let enabled = fields["enabled"]?.boolValue { rows.isEnabled = enabled }
        if let runner = fields["runnerDeviceID"] { rows.runnerDeviceID = runner.stringValue }
        if let created = fields["createdAt"]?.int64Value { rows.createdAt = SyncTime.cocoaSeconds(milliseconds: created) }
        if let schedule = fields["schedule"]?.objectValue {
            let zone = schedule["timezone"]?.stringValue
            let parts = AutomationSchedule.parts(ofRule: schedule["rrule"]?.stringValue, timeZoneID: zone)
            rows.timeZoneID = zone
            rows.cadence = parts.cadence
            rows.weekday = parts.weekday
            rows.dayOfMonth = parts.dayOfMonth
            rows.hour = parts.hour
            rows.minute = parts.minute
            // Only once names its day; another cadence's first eligible day stays as this Mac holds it.
            if parts.cadence == .once { rows.startDate = parts.startDate?.timeIntervalSinceReferenceDate }
        }
        try connection.execute("""
            INSERT INTO scheduled_tasks (id, title, instruction, notebook_id, cadence, weekday, day_of_month, hour, minute, time_zone,
                start_date, is_enabled, created_at, updated_at, runner_device_id)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?13, ?14)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title, instruction = excluded.instruction, notebook_id = excluded.notebook_id, cadence = excluded.cadence,
                weekday = excluded.weekday, day_of_month = excluded.day_of_month, hour = excluded.hour, minute = excluded.minute,
                time_zone = excluded.time_zone, start_date = excluded.start_date, is_enabled = excluded.is_enabled,
                created_at = excluded.created_at, runner_device_id = excluded.runner_device_id
        """, [
            .text(id), .text(rows.title), .text(rows.instruction), .text(rows.notebookID), .text(rows.cadence.rawValue),
            .integer(rows.weekday.map(Int64.init)), .integer(rows.dayOfMonth.map(Int64.init)), .integer(Int64(rows.hour)),
            .integer(Int64(rows.minute)), .text(rows.timeZoneID), .real(rows.startDate), .integer(rows.isEnabled ? 1 : 0),
            .real(rows.createdAt), .text(rows.runnerDeviceID),
        ])
        if let runs = fields["runs"]?.objectValue {
            try applyRuns(runs, taskID: id, connection: connection)
        }
        return .projected
    }

    /// The runner's ring into this Mac's receipts: each slot's run, by its occurrence, replacing the run
    /// the slot held before; an emptied slot's run goes. The task's last occurrence only ever moves on, so
    /// a Mac that becomes the runner never runs an occurrence again.
    private func applyRuns(_ runs: [String: SyncJSON], taskID: String, connection: SQLiteConnection) throws {
        for (slot, value) in runs.sorted(by: { $0.key < $1.key }) where AutomationRing.index(ofKey: slot) != nil {
            guard let run = value.objectValue, let runID = run["runID"]?.stringValue, let at = run["at"]?.int64Value else {
                try connection.execute("DELETE FROM scheduled_task_runs WHERE task_id = ? AND ring_slot = ?", [.text(taskID), .text(slot)])
                continue
            }
            let occurrence = SyncTime.cocoaSeconds(milliseconds: at)
            let session = run["outputRef"]?.stringValue.flatMap(ItemRef.init).flatMap { $0.kind == .chat ? $0.id : nil }
            try connection.execute("""
                DELETE FROM scheduled_task_runs WHERE task_id = ?1 AND (ring_slot = ?2 OR id = ?3) AND occurrence_at <> ?4
            """, [.text(taskID), .text(slot), .text(runID), .real(occurrence)])
            try connection.execute("""
                INSERT INTO scheduled_task_runs (id, task_id, occurrence_at, started_at, status, session_id, message, ring_slot)
                VALUES (?1, ?2, ?3, ?3, ?4, ?5, ?6, ?7)
                ON CONFLICT(task_id, occurrence_at) DO UPDATE SET
                    status = excluded.status, session_id = COALESCE(excluded.session_id, scheduled_task_runs.session_id),
                    message = COALESCE(excluded.message, scheduled_task_runs.message), ring_slot = excluded.ring_slot
            """, [
                .text(runID), .text(taskID), .real(occurrence), .text(run["status"]?.stringValue ?? "succeeded"), .text(session),
                .text(run["message"]?.stringValue), .text(slot),
            ])
        }
        try connection.execute("""
            UPDATE scheduled_tasks SET
                last_occurrence_at = MAX(COALESCE(last_occurrence_at, 0), (SELECT MAX(occurrence_at) FROM scheduled_task_runs WHERE task_id = ?1)),
                last_run_at = COALESCE((SELECT started_at FROM scheduled_task_runs WHERE task_id = ?1 ORDER BY occurrence_at DESC LIMIT 1), last_run_at),
                last_run_status = COALESCE((SELECT status FROM scheduled_task_runs WHERE task_id = ?1 ORDER BY occurrence_at DESC LIMIT 1), last_run_status)
            WHERE id = ?1 AND EXISTS (SELECT 1 FROM scheduled_task_runs WHERE task_id = ?1)
        """, [.text(taskID)])
    }

    func applyDeletion(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws {
        guard !record.zone.isSpace else { return }
        // Its receipts cascade with it.
        try connection.execute("DELETE FROM scheduled_tasks WHERE id = ?", [.text(record.localID)])
    }
}

// MARK: - What generation 2 keeps beside generation 1's scheduled-task writes

extension KnowledgeStore {
    /// This device's generation-2 id (`ck_clock`), the one its stamps carry; nil before it has one.
    func generation2DeviceID() throws -> String? {
        guard let json = try scalarText("SELECT clock_json FROM ck_clock WHERE id = 1") else { return nil }
        return (try? JSONDecoder().decode(StampClock.self, from: Data(json.utf8)))?.deviceID
    }

    /// Whether this Mac runs the scheduled task (`Automation.runnerDeviceID`, §3.5.29). A task names the
    /// one Mac that runs it, so two Macs never answer one morning; a task no Mac runs yet is taken by
    /// this one, and a Mac with no device id yet runs it without taking it. Runs inside the caller's
    /// transaction.
    func scheduledTaskRunsHere(_ taskID: String) throws -> Bool {
        guard let device = try generation2DeviceID() else { return true }
        let runner = try scalarText("SELECT runner_device_id FROM scheduled_tasks WHERE id = ?", [.text(taskID)])
        if let runner, !runner.isEmpty { return runner == device }
        try execute("UPDATE scheduled_tasks SET runner_device_id = ? WHERE id = ?", [.text(device), .text(taskID)])
        return true
    }

    /// A run this Mac just claimed takes the ring's next slot (§3.5.29, D42). Generation 2 only; inside the
    /// claim's transaction, before the receipts are pruned to the ring's size.
    func takeRingSlotForGeneration2(runID: String, taskID: String) throws {
        let slot = try AutomationRing.nextSlot(taskID: taskID, excluding: runID, connection: self)
        try execute("UPDATE scheduled_task_runs SET ring_slot = ? WHERE id = ?", [.text(slot), .text(runID)])
    }

    /// Run now on a Mac that does not run the task: a `Job(runAutomation)` for the Mac that does
    /// (§3.5.28), as the web asks for one. False when this Mac runs it (or has no device id yet), and the
    /// caller sets the task's run-now request here. Inside the caller's transaction.
    func requestRunOnRunnerMacForGeneration2(_ taskID: String, at date: Date) throws -> Bool {
        guard let device = try generation2DeviceID(),
              let runner = try scalarText("SELECT runner_device_id FROM scheduled_tasks WHERE id = ?", [.text(taskID)]),
              !runner.isEmpty, runner != device else { return false }
        try MacJobRequests.request(
            kind: "runAutomation", target: nil, params: ["automationID": .string(taskID)], device: device, at: date, connection: self
        )
        return true
    }
}
