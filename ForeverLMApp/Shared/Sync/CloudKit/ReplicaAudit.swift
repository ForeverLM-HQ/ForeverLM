import Foundation
import OSLog

/// The names-only walk that sweeps ghosts (docs/cloudkit-schema-design.md §2.3, §6.4, D30). A fetch
/// from a nil token returns the live records but never the deletions made while the token was
/// invalid, so after any such pass (an expired token, a discarded engine state, an account change, a
/// reinstall) and once a week, the replica walks the zone with `desiredKeys = []` and treats every row
/// the walk did not return as an inbound deletion, except a row acknowledged or delivered after the
/// walk began. Rows the walk returned are marked seen in it (`ck_records.seen_pass`), and the walk is
/// the zone's last complete pass (`ck_zones.last_complete_pass_at`), which the deterministic re-create
/// is gated on (§6.2): a record deleted while the token was invalid is never written back.
struct ReplicaAudit {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "ReplicaAudit")

    let transport: CloudTransport
    let store: PrivateSyncLocalStore
    let moveMaps: MoveMapIndex
    var clock: @Sendable () -> Date = { Date() }
    var pageSize: Int? = nil

    struct Result: Equatable, Sendable {
        var walked = 0
        var swept = 0
    }

    /// Walks `zone` and sweeps what the server no longer has. Throws when the walk cannot finish;
    /// nothing is swept then. A space is walked in the database that holds it, under its own key
    /// (SpaceSync, WP6); a private zone needs neither.
    @discardableResult
    func run(_ zone: CloudZoneID, in database: CloudDatabaseScope = .private, zoneKey: String? = nil) async throws -> Result {
        let zoneKey = zoneKey ?? PrivateSyncZones.key(zone)
        let passStart = clock()
        var names = Set<String>()
        var token: CloudChangeToken?
        while true {
            switch try await transport.zoneChanges(zone, in: database, since: token, desiredKeys: [], resultsLimit: pageSize) {
            case .failure(let error):
                throw error
            case .success(let page):
                names.formUnion(page.modified.map(\.id.recordName))
                // A record the server could not hand over is there all the same.
                names.formUnion(page.failed.keys.map(\.recordName))
                guard page.moreComing else { return try await sweep(zoneKey: zoneKey, names: names, passStart: passStart) }
                token = page.changeToken
            }
        }
    }

    private func sweep(zoneKey: String, names: Set<String>, passStart: Date) async throws -> Result {
        let moveMaps = moveMaps
        let now = clock()
        let result = try await store.perform { state -> Result in
            try state.replica.apply { replica -> Result in
                var result = Result(walked: names.count)
                let pass = passStart.timeIntervalSinceReferenceDate
                if var zone = try replica.zone(key: zoneKey) {
                    zone.lastCompletePassAt = pass
                    try replica.upsertZone(zone)
                }
                var rows: [(name: String, seen: Double?)] = []
                try state.connection.query("SELECT record_name, seen_pass FROM ck_records WHERE zone_key = ?", [.text(zoneKey)]) {
                    rows.append(($0.text(0) ?? "", $0.real(1)))
                }
                let applied = try InboundApply(state: state, now: now, passStart: passStart, moveMaps: moveMaps)
                for row in rows {
                    if names.contains(row.name) {
                        try state.connection.execute(
                            "UPDATE ck_records SET seen_pass = ? WHERE zone_key = ? AND record_name = ?",
                            [.real(pass), .text(zoneKey), .text(row.name)]
                        )
                        continue
                    }
                    // Acknowledged or delivered since the walk began: the walk could not have seen it.
                    if let seen = row.seen, seen >= pass { continue }
                    // The root is the bootstrap's to judge (§2.4).
                    if row.name == SyncSchema.rootRecordName { continue }
                    try applied.absorbDeletion(CloudRecordDeletion(id: CloudRecordID(row.name, in: CloudZoneID(ProjectionZones.zone(ofKey: zoneKey)?.name ?? "")), recordType: ""), zoneKey: zoneKey)
                    result.swept += 1
                }
                return result
            }
        }
        try await store.perform { try $0.replica.setEngineState(ReplicaStore.EngineScope.audit(zoneKey), Data("\(passStart.timeIntervalSinceReferenceDate)".utf8), now: now) }
        if result.swept > 0 { Self.logger.info("The replica audit swept \(result.swept) records from \(zoneKey, privacy: .public)") }
        return result
    }

    /// Whether the zone's weekly audit is due.
    static func isDue(_ zone: CloudZoneID, in state: PrivateSyncLocalState, now: Date, interval: TimeInterval) throws -> Bool {
        try isDue(zoneKey: PrivateSyncZones.key(zone), in: state, now: now, interval: interval)
    }

    static func isDue(zoneKey: String, in state: PrivateSyncLocalState, now: Date, interval: TimeInterval) throws -> Bool {
        guard let data = try state.replica.engineState(ReplicaStore.EngineScope.audit(zoneKey)),
              let last = Double(String(decoding: data, as: UTF8.self))
        else { return true }
        return now.timeIntervalSinceReferenceDate - last >= interval
    }
}
