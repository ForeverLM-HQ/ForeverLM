import Foundation
import Testing
@testable import ForeverLM

/// The ActivityLog record (docs/cloudkit-schema-design.md §3.5.24): this Mac's own day logs, the migrated
/// `legacy22` logs, and the day's fold into `source_activity_days` and `memory_review_activity`, where a
/// legacy log and a device log never count the same activity twice.
@Suite("Activity log projection")
struct ActivityLogProjectionTests {
    private typealias F = MemorySyncFixture
    private static let noon: Double = 780_000_000 - 780_000_000.truncatingRemainder(dividingBy: 86_400) + 43_200

    private static func source(_ store: KnowledgeStore, _ id: String) throws {
        try store.execute("INSERT INTO sources (id, date_added, state, source_type, status) VALUES (?, 1, 'ready', 'article', 'active')", [.text(id)])
    }

    @Test("This Mac's own log goes out, a source only after 30 s of use, and another device's log never")
    func ownLog() throws {
        let (root, store) = try F.makeStore("al-own")
        defer { try? FileManager.default.removeItem(at: root) }
        let at = Date(timeIntervalSinceReferenceDate: Self.noon)
        try store.recordOwnSourceActivity(sourceID: "src-1", kind: .reading, completed: false, fraction: 0.4, engagedSeconds: 20, at: at)
        try store.recordOwnSourceActivity(sourceID: "src-1", kind: .reading, completed: false, fraction: 0.6, engagedSeconds: 25, at: at.addingTimeInterval(60))
        try store.recordOwnSourceActivity(sourceID: "src-2", kind: .listening, completed: false, fraction: 0.1, engagedSeconds: 10, at: at)
        try store.recordOwnSourceActivity(sourceID: "src-3", kind: .review, completed: false, fraction: nil, engagedSeconds: 0, at: at)
        let day = F.day(Self.noon)
        let id = SyncIdentity.activityLogID(day: day, deviceID: F.deviceID)
        let fields = try #require(F.fields(try F.pending(store)["ActivityLog:\(id)"]))
        #expect(fields["day"] == .string(day) && fields["deviceID"] == .string(F.deviceID))
        let sources = try #require(fields["sources"]?.objectValue)
        #expect(Set(sources.keys) == ["src-1", "src-3"], "10 s of listening is not logged yet; a review is not timed")
        #expect(sources["src-1"]?["engagedSeconds"] == 45 && sources["src-1"]?["maxFraction"] == 0.6 && sources["src-1"]?["kinds"] == ["read"])

        try F.apply(store, [try F.record(.activityLog, SyncIdentity.activityLogID(day: day, deviceID: "iphoneaa"), [
            "day": .string(day), "deviceID": "iphoneaa",
            "sources": .object(["src-1": ["kinds": ["listen"], "completedKinds": [], "maxFraction": 0.9, "engagedSeconds": 300,
                                          "notebookIDs": [], "firstAt": 1_759_000_000_000, "lastAt": 1_759_000_300_000]]),
        ])])
        try store.execute("UPDATE activity_logs SET sources_json = '{}' WHERE device_id = 'iphoneaa'")
        #expect(try F.pending(store)["ActivityLog:\(SyncIdentity.activityLogID(day: day, deviceID: "iphoneaa"))"] == nil, "one writer")
    }

    @Test("The legacy logs hold every day's sources and old device clocks, and run twice to one result")
    func legacyLogs() throws {
        let (root, store) = try F.makeStore("al-legacy", triggers: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let dayStart = try #require(DayPlan.startOfDay(F.day(Self.noon))).timeIntervalSinceReferenceDate
        try store.execute("""
            INSERT INTO source_activity_days (id, scheduled_source_id, source_id, day_start, first_activity_at, last_activity_at, kinds,
                completed_kinds, max_fraction, engaged_seconds)
            VALUES ('d-1', 'pl-1', 'src-1', ?, ?, ?, 3, 1, 0.5, 600)
        """, [.real(dayStart), .real(Self.noon), .real(Self.noon + 600)])
        try store.execute("""
            INSERT INTO memory_review_activity (id, day, device_id, active_seconds, goal_seconds, updated_at)
            VALUES (?, ?, 'old-mac', 200, 900, ?), (?, ?, 'old-phone', 100, 900, ?)
        """, [
            .text(MemoryReviewGoal.activityID(day: F.day(Self.noon), deviceID: "old-mac")), .text(F.day(Self.noon)), .real(Self.noon),
            .text(MemoryReviewGoal.activityID(day: F.day(Self.noon), deviceID: "old-phone")), .text(F.day(Self.noon)), .real(Self.noon),
        ])
        try store.deriveLegacyActivityLogs()
        let first = try F.text(store, "SELECT sources_json || '|' || review_by_device_json FROM activity_logs WHERE device_id = 'legacy22'")
        try store.deriveLegacyActivityLogs()
        #expect(try F.text(store, "SELECT sources_json || '|' || review_by_device_json FROM activity_logs WHERE device_id = 'legacy22'") == first)
        let log = try #require(try ActivityLogProjection.loadLog(table: "activity_logs", day: F.day(Self.noon), deviceID: "legacy22", connection: store))
        #expect(log.sources["src-1"]?["kinds"] == ["listen", "read"] && log.sources["src-1"]?["completedKinds"] == ["read"])
        #expect(log.sources["src-1"]?["engagedSeconds"] == 600)
        #expect(log.reviewByDevice["old-mac"]?["activeSeconds"] == 200 && log.reviewByDevice["old-phone"]?["goalSeconds"] == 900)
        #expect(ActivityLogProjection.encodeRows(log)["reviewByDevice"]?.objectValue?.count == 2)
    }

    @Test("A legacy log and the device logs never count the same activity twice")
    func neverDoubleCounted() throws {
        let (root, store) = try F.makeStore("al-fold")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.source(store, "src-1")
        let day = F.day(Self.noon)
        let dayStart = try #require(DayPlan.startOfDay(day)).timeIntervalSinceReferenceDate
        // Generation 1 recorded 600 s before the activation, and the old review clock 200 s.
        try store.execute("""
            INSERT INTO source_activity_days (id, scheduled_source_id, source_id, day_start, first_activity_at, last_activity_at, kinds,
                completed_kinds, max_fraction, engaged_seconds)
            VALUES ('d-1', 'pl-1', 'src-1', ?, ?, ?, 1, 0, 0.5, 600)
        """, [.real(dayStart), .real(Self.noon), .real(Self.noon)])
        try store.execute("INSERT INTO memory_review_activity (id, day, device_id, active_seconds, goal_seconds, updated_at) VALUES (?, ?, 'old-mac', 200, 900, ?)",
                          [.text(MemoryReviewGoal.activityID(day: day, deviceID: "old-mac")), .text(day), .real(Self.noon)])
        try store.replica.apply { _ in try store.deriveLegacyActivityLogs() }

        // After it, this Mac logs 120 s more and its old review row reaches 300 s; the phone logs 60 s.
        try store.recordOwnSourceActivity(sourceID: "src-1", kind: .reading, completed: false, fraction: 0.7, engagedSeconds: 120,
                                          at: Date(timeIntervalSinceReferenceDate: Self.noon + 3_600))
        try store.recordOwnReviewActivity(MemoryReviewActivity(day: day, deviceID: "old-mac", activeSeconds: 300, goalSeconds: 900,
                                                               updatedAt: Date(timeIntervalSinceReferenceDate: Self.noon + 3_600)))
        let own = try #require(try store.loadDeviceActivityLog(day: day, deviceID: F.deviceID))
        #expect(own.review?["seconds"] == 100, "the clock less what the legacy log holds for the same old device")
        #expect(own.sources["src-1"]?["engagedSeconds"] == 120, "only what was recorded after the activation")

        try F.apply(store, [try F.record(.activityLog, SyncIdentity.activityLogID(day: day, deviceID: "iphoneaa"), [
            "day": .string(day), "deviceID": "iphoneaa",
            "sources": .object(["src-1": ["kinds": ["read"], "completedKinds": ["read"], "maxFraction": 1, "engagedSeconds": 60,
                                          "notebookIDs": [], "firstAt": 1_759_000_000_000, "lastAt": 1_759_000_060_000]]),
            "review": ["seconds": 50, "goalSeconds": 900, "at": 1_759_000_060_000],
        ])])
        // The fold: 600 (generation 1) + 120 (this Mac since) + 60 (the phone); never 600 twice.
        #expect(try store.scalarText("SELECT CAST(engaged_seconds AS TEXT) FROM source_activity_days WHERE source_id = 'src-1'").flatMap(Double.init) == 780)
        #expect(try F.count(store, "SELECT COUNT(*) FROM source_activity_days WHERE source_id = 'src-1'") == 1)
        #expect(try F.count(store, "SELECT completed_kinds FROM source_activity_days WHERE source_id = 'src-1'") == 1)
        // The review clock read as the sum of rows: 200 (old Mac row) + 50 (the phone's), and this Mac's own row is its recorder's.
        #expect(try store.scalarText("SELECT CAST(SUM(active_seconds) AS TEXT) FROM memory_review_activity WHERE day = ? AND device_id != 'old-mac'", [.text(day)]).flatMap(Double.init) == 50)
        #expect(try F.count(store, "SELECT COUNT(*) FROM memory_review_activity WHERE device_id = 'al:iphoneaa'") == 1)
    }

    @Test("A log naming a source this Mac does not hold applies, folds the held sources, and folds again when the Source lands")
    func unheldSourceDoesNotJamTheApply() throws {
        let (root, store) = try F.makeStore("al-unheld")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.source(store, "src-held")
        let day = F.day(Self.noon)
        let element: SyncJSON = ["kinds": ["read"], "completedKinds": [], "maxFraction": 0.5, "engagedSeconds": 90,
                                 "notebookIDs": [], "firstAt": 1_759_000_000_000, "lastAt": 1_759_000_090_000]
        try F.apply(store, [try F.record(.activityLog, SyncIdentity.activityLogID(day: day, deviceID: "iphoneaa"), [
            "day": .string(day), "deviceID": "iphoneaa", "sources": .object(["src-held": element, "src-late": element]),
        ])])
        #expect(try F.count(store, "SELECT COUNT(*) FROM activity_logs WHERE device_id = 'iphoneaa'") == 1, "the log itself is kept")
        #expect(try F.count(store, "SELECT COUNT(*) FROM source_activity_days WHERE source_id = 'src-held'") == 1)
        #expect(try F.count(store, "SELECT COUNT(*) FROM source_activity_days WHERE source_id = 'src-late'") == 0)
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_unprojected WHERE waiting_on_type = 'Source' AND waiting_on_id = 'src-late'") == 1,
                "the record waits for the Source it names")

        try Self.source(store, "src-late")
        #expect(try store.drainReadyProjections() == 1)
        #expect(try F.count(store, "SELECT COUNT(*) FROM source_activity_days WHERE source_id = 'src-late'") == 1, "folded when the Source lands")
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_unprojected") == 0)
    }

    /// One work held twice: the personal copy, and a team's copy on the personal copy's wire id. Both have
    /// the same URL, so the same portable key and so the same `source_activity_days` id for a day.
    private static func personalAndTeamCopy(_ store: KnowledgeStore) throws {
        for (id, team, wire) in [("src-p", nil, nil), ("src-t", "team-1", "src-p")] as [(String, String?, String?)] {
            try store.execute("""
                INSERT INTO sources (id, date_added, state, source_type, status, team_id, wire_id) VALUES (?, 1, 'ready', 'article', 'active', ?, ?)
            """, [.text(id), team.map(SQLiteValue.text) ?? .null, wire.map(SQLiteValue.text) ?? .null])
            try store.execute("""
                INSERT INTO articles (source_id, url, normalized_url, title, domain) VALUES (?, 'https://example.org/work', 'example.org/work', 'Work', 'example.org')
            """, [.text(id)])
        }
    }

    @Test("A legacy log whose day generation 1 recorded on a team copy folds onto the personal copy instead of failing the row id")
    func teamCopysDayFoldsOntoThePersonalCopy() throws {
        // The rehearsal on the production library parked 7 of 52 legacy logs as projectionFailed: the refold's
        // upsert on (source_id, day_start) for the personal copy met the team copy's row holding the same id.
        let (root, store) = try F.makeStore("al-team-copy")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.personalAndTeamCopy(store)
        let day = F.day(Self.noon)
        let dayStart = try #require(DayPlan.startOfDay(day))
        let rowID = MemoryTutorIdentity.sourceActivityDayID(portableSourceKey: try store.portableMemorySourceKey(sourceID: "src-t"), dayStart: dayStart)
        #expect(rowID == MemoryTutorIdentity.sourceActivityDayID(portableSourceKey: try store.portableMemorySourceKey(sourceID: "src-p"), dayStart: dayStart),
                "both copies name one work's day")
        try store.execute("""
            INSERT INTO source_activity_days (id, scheduled_source_id, source_id, day_start, first_activity_at, last_activity_at, kinds,
                completed_kinds, max_fraction, engaged_seconds)
            VALUES (?, 'pl-1', 'src-t', ?, ?, ?, 1, 0, 0.5, 600)
        """, [.text(rowID), .real(dayStart.timeIntervalSinceReferenceDate), .real(Self.noon), .real(Self.noon + 600)])
        try store.replica.apply { _ in try store.deriveLegacyActivityLogs() }
        let log = try #require(try ActivityLogProjection.loadLog(table: "activity_logs", day: day, deviceID: SyncIdentity.migratedHistoryDeviceID, connection: store))
        #expect(Set(log.sources.keys) == ["src-p"], "the log names the work by its wire id")

        try F.apply(store, [try F.record(.activityLog, SyncIdentity.activityLogID(day: day, deviceID: SyncIdentity.migratedHistoryDeviceID),
                                         ActivityLogProjection.encodeRows(log))])
        #expect(try F.count(store, "SELECT COUNT(*) FROM source_activity_days WHERE day_start = ?", [.real(dayStart.timeIntervalSinceReferenceDate)]) == 1,
                "one row for the work's day")
        #expect(try F.text(store, "SELECT source_id FROM source_activity_days WHERE id = ?", [.text(rowID)]) == "src-p")
        #expect(try store.scalarText("SELECT CAST(engaged_seconds AS TEXT) FROM source_activity_days WHERE id = ?", [.text(rowID)]).flatMap(Double.init) == 600)
    }

    @Test("Using the personal copy on a day its team copy was used adds to the work's one row for the day")
    func recorderAdoptsTheTeamCopysDay() throws {
        let (root, store) = try F.makeStore("al-team-copy-recorder")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.personalAndTeamCopy(store)
        let at = Date(timeIntervalSinceReferenceDate: Self.noon)
        try store.recordScheduledSourceActivity(sourceID: "src-t", on: at, kind: .reading, engagedSeconds: 40)
        try store.recordScheduledSourceActivity(sourceID: "src-p", on: at, kind: .reading, engagedSeconds: 50)
        #expect(try F.count(store, "SELECT COUNT(*) FROM source_activity_days") == 1)
        #expect(try F.text(store, "SELECT source_id FROM source_activity_days") == "src-p")
        #expect(try store.scalarText("SELECT CAST(engaged_seconds AS TEXT) FROM source_activity_days").flatMap(Double.init) == 90)
    }

    @Test("Under generation 1 the recorders write only build 177's rows")
    func generation1() throws {
        let root = try Schema154Fixture.temporaryRoot("al-g1")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)
        try store.recordOwnSourceActivity(sourceID: "src-1", kind: .reading, completed: false, fraction: 0.4, engagedSeconds: 60, at: Date())
        try store.recordOwnReviewActivity(MemoryReviewActivity(day: "2026-10-04", deviceID: "x", activeSeconds: 1, goalSeconds: 1, updatedAt: Date()))
        #expect(try F.count(store, "SELECT COUNT(*) FROM device_activity_days") == 0)
    }
}
