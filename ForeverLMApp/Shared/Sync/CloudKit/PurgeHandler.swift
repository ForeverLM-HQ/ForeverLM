import Foundation
import OSLog

/// What happens when the private library leaves iCloud (docs/cloudkit-schema-design.md §2.5, D37):
/// the learner removed ForeverLM's data in iCloud settings (`.purged`, or `userDeletedZone` on a save
/// or fetch), another of their devices ran "Remove all my ForeverLM iCloud data" (`.deleted`), they
/// reset their encrypted data (`.encryptedDataReset`, handled like a purge until DTS answers, §15
/// Q3), the zone or its root is missing after the bootstrap, the root names another salt, or the
/// account changed.
///
/// The device stops sending to the private database and remembers why (`ck_engine_state`
/// `private.stop`), so a relaunch does not start again on its own; it keeps `knowledge.db`, every
/// local file and the outbox (the learner's own changes) intact, and drops what described the
/// server: the replica's rows of the private zones, their tokens, what waited on them, delete and
/// echo bookkeeping, and stamps pinned against the old records. The `ck_zones` rows stay with their
/// `saltID`, so the bootstrap goes on finding a purge and never re-creates a zone by itself (§2.4 step
/// 5); only `reupload()`, the learner's "Upload my library to iCloud again", clears them, and the next
/// bootstrap makes new zones with a new salt.
enum PurgeHandler {
    enum Event: Equatable, Sendable {
        /// A private zone's deletion, with its reason; `userDeletedZone` is `.purged`.
        case zoneDeleted(reason: CloudZoneDeletionReason)
        /// The zone or its root is missing after the bootstrap (`zoneNotFound`, `unknownItem`).
        case rootMissing
        /// The root names another salt than the one this device holds: the library was uploaded
        /// again elsewhere, and records named with the old salt are dead.
        case saltChanged
        /// The iCloud account signed out (`signedOut`) or became another one.
        case accountChanged(signedOut: Bool)

        var code: String {
            switch self {
            case .zoneDeleted(let reason): return "zoneDeleted.\(reason.rawValue)"
            case .rootMissing: return "rootMissing"
            case .saltChanged: return "saltChanged"
            case .accountChanged(let signedOut): return signedOut ? "signedOut" : "accountSwitched"
            }
        }

        init?(code: String) {
            switch code {
            case "rootMissing": self = .rootMissing
            case "saltChanged": self = .saltChanged
            case "signedOut": self = .accountChanged(signedOut: true)
            case "accountSwitched": self = .accountChanged(signedOut: false)
            default:
                guard code.hasPrefix("zoneDeleted."),
                      let reason = CloudZoneDeletionReason(rawValue: String(code.dropFirst("zoneDeleted.".count)))
                else { return nil }
                self = .zoneDeleted(reason: reason)
            }
        }

        /// Whether the server's copy of the library is gone (or not this account's), so the replica
        /// no longer describes anything. A sign-out keeps it: the same account comes back.
        var dropsReplica: Bool { self != .accountChanged(signedOut: true) }
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "PurgeHandler")

    /// Stops the private database for `event` and drops what described the server. Runs in one
    /// transaction; generation 2 only (the engine and the bootstrap are its only callers).
    static func handle(_ event: Event, in state: PrivateSyncLocalState, now: Date = Date()) throws {
        let connection = state.connection
        let replica = state.replica
        try connection.executeScript("BEGIN IMMEDIATE")
        do {
            try replica.setEngineState(ReplicaStore.EngineScope.privateStop, Data(event.code.utf8), now: now)
            if event.dropsReplica {
                for zone in PrivateSyncZones.all {
                    let key = PrivateSyncZones.key(zone)
                    for table in ["ck_records", "ck_unprojected", "ck_pending_deletes", "ck_echo", "ck_quarantine", "ck_text_bases"] {
                        try connection.execute("DELETE FROM \(table) WHERE zone_key = ?", [.text(key)])
                    }
                    // Stamps pinned against the old records go; the outbox rows they were minted for stay.
                    if try connection.scalarInteger("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'ck_outbox_fields'") == 1 {
                        try connection.execute(
                            "DELETE FROM ck_outbox_fields WHERE source_table = ? AND substr(local_key, 1, ?) = ?",
                            [.text(OutboxFeeder.pinSource), .integer(Int64(key.count + 1)), .text(key + "\u{1F}")]
                        )
                    }
                    try connection.execute(
                        "UPDATE ck_zones SET change_token = NULL, last_complete_pass_at = NULL WHERE zone_key = ?", [.text(key)]
                    )
                }
                try replica.setEngineState(ReplicaStore.EngineScope.privateEngine, nil)
            }
            try connection.executeScript("COMMIT")
        } catch {
            try? connection.executeScript("ROLLBACK")
            throw error
        }
        logger.error("Stopped syncing the private library: \(event.code, privacy: .public)")
    }

    /// Why the private database stopped, if it did.
    static func stopReason(in state: PrivateSyncLocalState) throws -> Event? {
        try state.replica.engineState(ReplicaStore.EngineScope.privateStop).flatMap { Event(code: String(decoding: $0, as: UTF8.self)) }
    }

    /// The same account signed in again after a sign-out: syncing resumes where it stopped.
    static func resumeAfterSignIn(in state: PrivateSyncLocalState) throws {
        guard try stopReason(in: state) == .accountChanged(signedOut: true) else { return }
        try state.replica.setEngineState(ReplicaStore.EngineScope.privateStop, nil)
    }

    /// "Upload my library to iCloud again" (§2.5): forgets the old zones and salt, so the next
    /// bootstrap creates new ones; the seed that uploads the library follows it (§13.4).
    static func reupload(in state: PrivateSyncLocalState) throws {
        let connection = state.connection
        // The seed's tables exist on a Mac only.
        func hasTable(_ name: String) throws -> Bool {
            try connection.scalarInteger("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(name)]) == 1
        }
        try connection.executeScript("BEGIN IMMEDIATE")
        do {
            for zone in PrivateSyncZones.all {
                let key = PrivateSyncZones.key(zone)
                for table in ["ck_records", "ck_unprojected", "ck_pending_deletes", "ck_echo", "ck_zones", "ck_blobs", "ck_blob_jobs", "ck_manifest_pending"] where try hasTable(table) {
                    try connection.execute("DELETE FROM \(table) WHERE zone_key = ?", [.text(key)])
                }
            }
            // The seed's cursors say which passes already uploaded the library, to the old zones. Left in
            // place, the new root's seed finds every pass done and uploads nothing: the library stays on
            // the Mac and no other device ever sees it.
            if try hasTable("ck_seed_cursor") { try connection.execute("DELETE FROM ck_seed_cursor") }
            for scope in [ReplicaStore.EngineScope.privateStop, ReplicaStore.EngineScope.privateEngine, ReplicaStore.EngineScope.zonesCreated] {
                try state.replica.setEngineState(scope, nil)
            }
            try connection.executeScript("COMMIT")
        } catch {
            try? connection.executeScript("ROLLBACK")
            throw error
        }
    }
}
