import Foundation
import Testing
@testable import ForeverLM

/// The Automation projection (docs/cloudkit-schema-design.md §3.5.29, D42, WP14): a scheduled task's
/// cadence as the web's RFC 5545 rule, both ways; its runs as a fixed ring of 20 slots that never grows;
/// one runner Mac per task; Run now from another Mac as a `Job(runAutomation)`; the activation's slots.
@Suite("Automation projection")
struct AutomationProjectionTests {
    typealias F = NotebookSyncFixture

    private static func store(_ name: String) throws -> (URL, KnowledgeStore) {
        let (root, store) = try F.makeStore("automation-\(name)")
        try F.prepareReplica(store)
        return (root, store)
    }

    private static func task(_ id: String = "auto-1", cadence: ScheduledTaskCadence = .daily) -> ScheduledTask {
        ScheduledTask(
            id: id, title: "Morning brief", instruction: "Summarize yesterday", cadence: cadence, weekday: 4, dayOfMonth: 15,
            hour: 7, minute: 30, timeZoneID: "Europe/Amsterdam", startDate: Date(timeIntervalSinceReferenceDate: 812_000_000),
            createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000), updatedAt: Date(timeIntervalSinceReferenceDate: 800_000_000)
        )
    }

    private static func occurrence(_ n: Int) -> Date { Date(timeIntervalSinceReferenceDate: 812_000_000 + Double(n) * 86_400) }

    @Test("Each cadence is the web's rule, and the rule reads back as the same cadence")
    func rules() throws {
        let zone = "Europe/Amsterdam"
        let created = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let start = Date(timeIntervalSinceReferenceDate: 812_000_000) // 2026-09-25 in Amsterdam
        let cases: [(ScheduledTaskCadence, String)] = [
            (.daily, "FREQ=DAILY;BYHOUR=7;BYMINUTE=30"),
            (.weekdays, "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=7;BYMINUTE=30"),
            (.weekly, "FREQ=WEEKLY;BYDAY=WE;BYHOUR=7;BYMINUTE=30"),
            (.monthly, "FREQ=MONTHLY;BYMONTHDAY=15;BYHOUR=7;BYMINUTE=30"),
            (.once, "FREQ=DAILY;COUNT=1;DTSTART=20260925;BYHOUR=7;BYMINUTE=30"),
        ]
        for (cadence, expected) in cases {
            let rule = AutomationSchedule.rule(cadence: cadence, weekday: 4, dayOfMonth: 15, hour: 7, minute: 30, startDate: start,
                                               createdAt: created, timeZoneID: zone)
            #expect(rule == expected, "\(cadence)")
            let parts = AutomationSchedule.parts(ofRule: rule, timeZoneID: zone)
            #expect(parts.cadence == cadence && parts.hour == 7 && parts.minute == 30, "\(cadence)")
            #expect(parts.weekday == (cadence == .weekly ? 4 : nil) && parts.dayOfMonth == (cadence == .monthly ? 15 : nil), "\(cadence)")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        let once = AutomationSchedule.parts(ofRule: cases[4].1, timeZoneID: zone)
        #expect(once.startDate == calendar.startOfDay(for: start), "once runs on its day in its zone")
        #expect(AutomationSchedule.parts(ofRule: "FREQ=WEEKLY;BYDAY=SU", timeZoneID: zone).weekday == 1)
        #expect(AutomationSchedule.parts(ofRule: nil, timeZoneID: nil) == AutomationSchedule.Parts(cadence: .daily, hour: 8, minute: 0))
    }

    @Test("A task's fields encode as the web reads them, and its first run makes this Mac its runner")
    func fieldsAndRunner() throws {
        let (root, store) = try Self.store("fields")
        defer { try? FileManager.default.removeItem(at: root) }
        try store.saveScheduledTask(Self.task(cadence: .weekly))
        var fields = try #require(F.savedFields(try F.pending(store)["Automation:auto-1"]))
        #expect(fields["title"] == .string("Morning brief") && fields["prompt"] == .string("Summarize yesterday"))
        #expect(fields["schedule"] == .object(["rrule": .string("FREQ=WEEKLY;BYDAY=WE;BYHOUR=7;BYMINUTE=30"), "timezone": .string("Europe/Amsterdam")]))
        #expect(fields["enabled"] == .bool(true) && fields["runnerDeviceID"] == nil)
        #expect(fields["createdAt"] == SyncJSON(SyncTime.milliseconds(cocoaSeconds: 800_000_000)))

        let run = try #require(try store.claimScheduledTaskOccurrence(taskID: "auto-1", occurrenceAt: Self.occurrence(1)))
        try store.finishScheduledTaskRun(runID: run.id, status: .succeeded, sessionID: "chat-1", message: nil)
        fields = try #require(F.savedFields(try F.pending(store)["Automation:auto-1"]))
        #expect(fields["runnerDeviceID"] == .string("macaaaaa"))
        #expect(fields["runs"] == .object(["slot0": .object([
            "runID": .string(run.id), "at": SyncJSON(SyncTime.milliseconds(Self.occurrence(1))), "status": .string("succeeded"),
            "outputRef": .string("cht:chat-1"),
        ])]))
    }

    @Test("Run n takes slot n mod 20: twenty-five runs fill the ring once and reuse its first five slots, and a run sends one slot")
    func twentySlotRing() throws {
        let (root, store) = try Self.store("ring")
        defer { try? FileManager.default.removeItem(at: root) }
        try store.saveScheduledTask(Self.task())
        var runs: [ScheduledTaskRun] = []
        for n in 1...25 {
            runs.append(try #require(try store.claimScheduledTaskOccurrence(taskID: "auto-1", occurrenceAt: Self.occurrence(n), status: .succeeded)))
        }
        let ring = try #require(F.savedFields(try F.pending(store)["Automation:auto-1"])?["runs"]?.objectValue)
        #expect(ring.count == 20, "the map never grows past its ring")
        #expect(Set(ring.keys) == Set((0..<20).map { "slot\($0)" }))
        #expect(ring["slot0"]?["runID"] == .string(runs[20].id), "run 21 took slot 0")
        #expect(ring["slot4"]?["runID"] == .string(runs[24].id))
        #expect(ring["slot5"]?["runID"] == .string(runs[5].id), "run 6 is still in slot 5")
        #expect(try F.count(store, "SELECT COUNT(*) FROM scheduled_task_runs WHERE task_id = 'auto-1'") == 20)

        try F.sendAll(store)
        let next = try #require(try store.claimScheduledTaskOccurrence(taskID: "auto-1", occurrenceAt: Self.occurrence(26), status: .succeeded))
        let change = try #require(try F.pending(store)["Automation:auto-1"])
        #expect(change.stamps.keys.map(\.description).sorted() == [StampedPath("runs", element: "slot5").description], "one slot moves")
        #expect(F.savedFields(change)?["runs"]?["slot5"]?["runID"] == .string(next.id))
    }

    @Test("A task another Mac runs is never claimed here, and Run now asks that Mac with a Job")
    func anotherMacRunsIt() throws {
        let (root, store) = try Self.store("other")
        defer { try? FileManager.default.removeItem(at: root) }
        try store.saveScheduledTask(Self.task())
        try store.execute("UPDATE scheduled_tasks SET runner_device_id = 'macbbbbb' WHERE id = 'auto-1'")
        #expect(try store.claimScheduledTaskOccurrence(taskID: "auto-1", occurrenceAt: Self.occurrence(1)) == nil)
        #expect(try F.count(store, "SELECT COUNT(*) FROM scheduled_task_runs") == 0)

        try store.requestScheduledTaskRunNow("auto-1")
        #expect(try F.count(store, "SELECT COUNT(*) FROM scheduled_tasks WHERE run_now_requested_at IS NOT NULL") == 0)
        let jobID = try #require(try F.text(store, "SELECT id FROM jobs WHERE kind = 'runAutomation'"))
        let job = try #require(F.savedFields(try F.pending(store)["Job:\(jobID)"]))
        #expect(job["params"] == .object(["automationID": .string("auto-1")]))
        #expect(job["status"] == .string("queued"))
        #expect(job["requestedBy"] == .object(["device": .string("macaaaaa"), "platform": .string("mac")]))
        #expect(job["expiresAt"]?.int64Value == job["requestedAt"]?.int64Value.map { $0 + 7 * 86_400_000 })
    }

    @Test("An Automation from the web lands as a scheduled task with its receipts, and the runner's last run is never run again here")
    func inboundAutomation() throws {
        let (root, store) = try Self.store("inbound")
        defer { try? FileManager.default.removeItem(at: root) }
        let at = SyncTime.milliseconds(Self.occurrence(3))
        try F.apply(store, [try F.record(.automation, "auto-web", [
            "title": .string("Weekly review"), "prompt": .string("What did I read?"),
            "schedule": .object(["rrule": .string("FREQ=WEEKLY;BYDAY=FR;BYHOUR=18;BYMINUTE=0"), "timezone": .string("America/New_York")]),
            "enabled": .bool(true), "runnerDeviceID": .string("macbbbbb"), "createdAt": SyncJSON(Int64(1_759_000_000_000)),
            "runs": .object(["slot0": .object(["runID": .string("run-b"), "at": SyncJSON(at), "status": .string("succeeded"), "outputRef": .string("cht:chat-b")])]),
        ])])
        let task = try #require(try store.loadScheduledTask("auto-web"))
        #expect(task.cadence == .weekly && task.weekday == 6 && task.hour == 18 && task.minute == 0)
        #expect(task.timeZoneID == "America/New_York" && task.isEnabled)
        #expect(task.lastOccurrenceAt == SyncTime.date(milliseconds: at), "the runner's run stays claimed")
        let runs = try store.loadScheduledTaskRuns(taskID: "auto-web")
        #expect(runs.map(\.id) == ["run-b"] && runs.first?.sessionID == "chat-b" && runs.first?.status == .succeeded)
        #expect(try F.pending(store).isEmpty, "an applied record sends nothing back")
    }

    @Test("The activation gives the newest twenty runs their slots, oldest first, and a second run changes nothing")
    func activationSlots() throws {
        let (root, store) = try Self.store("activation")
        defer { try? FileManager.default.removeItem(at: root) }
        try store.execute("INSERT INTO scheduled_tasks (id, title, instruction, created_at, updated_at) VALUES ('auto-1', 'Brief', 'Go', 1, 1)")
        for n in 1...22 {
            try store.execute(
                "INSERT INTO scheduled_task_runs (id, task_id, occurrence_at, started_at, status) VALUES (?, 'auto-1', ?, ?, 'succeeded')",
                [.text("run-\(n)"), .real(Double(n)), .real(Double(n))]
            )
        }
        try store.deriveAutomationRings()
        let slots = { try F.text(store, "SELECT group_concat(id || '=' || COALESCE(ring_slot, '-'), ',') FROM (SELECT id, ring_slot FROM scheduled_task_runs ORDER BY occurrence_at)") }
        let first = try slots()
        #expect(first?.hasPrefix("run-1=-,run-2=-,run-3=slot0,run-4=slot1") == true)
        #expect(first?.hasSuffix("run-22=slot19") == true)
        try store.deriveAutomationRings()
        #expect(try slots() == first)
    }
}
