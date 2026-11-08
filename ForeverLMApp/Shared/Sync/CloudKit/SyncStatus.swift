import Foundation

/// What the generation-2 private sync is doing, as `SyncCoordinator` publishes it
/// (docs/cloudkit-schema-design.md §2.5, §14.1). WP16 moves generation 1's status types
/// (`CloudKitSyncStatusCenter` and its neighbours) next to it and feeds them from this under
/// generation 2; until then nothing shows it.
struct SyncStatus: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// Not started, or no library container in this build.
        case idle
        /// Checking the account and the library's root.
        case starting
        /// No iCloud account, or one that cannot be used now.
        case noAccount
        /// The root is not there yet and this device may not make it now (§2.4).
        case waiting(ZoneBootstrap.Waiting)
        /// An iPhone whose account still has its library in the old container (§13.6).
        case staysOnGeneration1
        /// The library's root asks for a newer build (§12.5).
        case updateRequired(minClientRevision: Int)
        case syncing
        case upToDate
        /// The private database stopped (§2.5) until the learner acts.
        case stopped(PurgeHandler.Event)
        /// The last start or round failed, for the reason given; the next round tries again. A failure
        /// never reads as `idle` ("not started") or `upToDate`, and it leaves `lastSyncedAt` as it was.
        case failed(String)
    }

    var phase: Phase = .idle
    var pendingChanges = 0
    var lastSyncedAt: Date?
    /// Why the pacer holds the engine, if it does.
    var pause: SyncPacerState.PauseReason?

    /// The sentence Settings › iCloud shows for a stop (§2.5), nil when there is none.
    var notice: String? {
        switch phase {
        case .stopped(.zoneDeleted(.purged)), .stopped(.rootMissing), .stopped(.saltChanged):
            return "Your ForeverLM data was removed from iCloud. Your library on this Mac is intact; Upload my library to iCloud again to sync it."
        case .stopped(.zoneDeleted(.deleted)):
            return "Another of your devices removed your ForeverLM data from iCloud. Your library on this Mac is intact."
        case .stopped(.zoneDeleted(.encryptedDataReset)):
            return "Your iCloud encrypted data was reset, which removed your ForeverLM data from iCloud. Your library on this Mac is intact."
        case .stopped(.accountChanged(signedOut: true)):
            return "Sign in to iCloud to sync your library."
        case .stopped(.accountChanged(signedOut: false)):
            return "This Mac's iCloud account changed. Your library was not uploaded to the new account."
        case .updateRequired:
            return "Update ForeverLM to keep syncing your library."
        case .failed(let reason):
            return "The last sync with iCloud failed: \(reason) ForeverLM will try again."
        default:
            // A full iCloud: in someone else's space, the owner's (§2.5).
            guard case .quotaExceeded(let owner)? = pause else { return nil }
            return ShareService.quotaNotice(owner: owner)
        }
    }
}
