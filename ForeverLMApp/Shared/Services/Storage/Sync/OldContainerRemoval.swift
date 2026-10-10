import Foundation
import OSLog

/// "Remove old iCloud data" (docs/cloudkit-schema-design.md §13.8): the gate, its dialog and the
/// removal of the old container's `Knowledge` and `Team-*` zones.
///
/// The button is enabled only when (a) late import has been quiet for 7 days, (b) the byte parity
/// report is clean, and the learner confirms (c) in a dialog that lists what remains, the last
/// old-zone activity and every old record still waiting. Late import polls daily, so a write may have
/// landed since the last poll: confirming first runs one more import pass, and if that pass finds any
/// old-zone write the removal is aborted, the write is imported, and the 7-day wait starts again
/// (R3-m13). After the removal rollback needs a re-seed of the old container (§13.9), so nothing here
/// runs on a store the activation has not finished, and nothing runs without an importer.
struct OldContainerRemovalGate: Equatable, Sendable {
    static let quietDays = 7
    static let quietInterval: TimeInterval = Double(quietDays) * 24 * 3_600

    enum Blocker: Equatable, Sendable {
        /// Late import is not running on this Mac (no importer registered, or its state unreadable).
        case importUnavailable
        /// Old-zone writes were seen within the last 7 days, or the importer has not marked it quiet.
        case notQuiet(daysLeft: Int)
        /// Old assets with neither a new satellite nor a local file.
        case parityNotClean(missing: Int)
        /// An import pass or a refresh waits for Apply or Keep.
        case questionWaiting
        /// The old zones hold ideas, research directions or skills, which nothing of the new world carries
        /// (no Mac projection holds them yet, F12): deleting the zones would delete their only synced copy.
        case notCarried(count: Int)
        /// The old zones could not be read to count them, so nothing is known about what only they hold.
        case oldZonesUnreadable
        case alreadyRemoved
    }

    /// The old record types no step of the activation, the mapping or the late import carries to the new
    /// world. Until a package projects them (§10's Idea and skill rows), removal is refused while the old
    /// zones hold any.
    static let uncarriedEntities: [CloudKitSyncEntity] = [.idea, .researchDirection, .skill]

    var blockers: [Blocker]

    var isOpen: Bool { blockers.isEmpty }

    static func evaluate(facts: OldContainerImportFacts?, parity: ByteParityReport?, notCarried: Int? = 0, now: Date) -> OldContainerRemovalGate {
        guard let facts else { return OldContainerRemovalGate(blockers: [.importUnavailable]) }
        if facts.removedAt != nil { return OldContainerRemovalGate(blockers: [.alreadyRemoved]) }
        var blockers: [Blocker] = []
        let quiet = facts.finishedAt != nil && (facts.quietSince.map { now.timeIntervalSince($0) >= quietInterval } ?? false)
        if !quiet {
            let left = facts.quietSince.map { max(1, Int(ceil((quietInterval - now.timeIntervalSince($0)) / 86_400))) } ?? quietDays
            blockers.append(.notQuiet(daysLeft: min(left, quietDays)))
        }
        if let parity {
            if !parity.isClean { blockers.append(.parityNotClean(missing: parity.missing.count)) }
        } else {
            blockers.append(.parityNotClean(missing: 0))
        }
        if facts.question != nil { blockers.append(.questionWaiting) }
        if let notCarried {
            if notCarried > 0 { blockers.append(.notCarried(count: notCarried)) }
        } else {
            blockers.append(.oldZonesUnreadable)
        }
        return OldContainerRemovalGate(blockers: blockers)
    }
}

/// What the confirmation dialog names (§13.8): what remains, the last old-zone activity and every old
/// record still waiting, so the learner knows what removing the old zones would leave behind.
struct OldContainerRemovalDialog: Equatable, Sendable {
    var lastOldZoneWriteAt: Date?
    var missingTitles: [String]
    var waiting: [OldContainerImportFacts.WaitingRecord]
    var keptRemovals: Int
    var notApplied: Int
    var zones: [String]

    var remainsNothing: Bool { missingTitles.isEmpty && waiting.isEmpty }
}

struct OldContainerRemoval: Sendable {
    enum Abort: Equatable, Sendable {
        /// The final pass found old-zone writes. They are imported, and the 7-day wait starts again.
        case oldZoneWrites(count: Int)
        /// The final pass would delete more than 5% and asks the learner first.
        case guardQuestion
        /// The final pass could not run.
        case passFailed(String)
    }

    enum Result: Equatable, Sendable {
        /// The learner has not confirmed in the dialog.
        case notConfirmed
        case refused([OldContainerRemovalGate.Blocker])
        /// Nothing was deleted.
        case aborted(Abort)
        case removed(zones: [String])
        /// Some zones were deleted and some were not.
        case failed(String)
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "OldContainerRemoval")

    /// The zones the removal deletes: the learner's own `Knowledge` and `Team-*` zones of the old
    /// container. A team zone another person owns lives in the shared database and is left to its owner.
    static func removableZoneNames(_ zones: [CloudZoneID]) -> [CloudZoneID] {
        zones.filter { $0.ownerName == CloudZoneID.currentUser && ($0.zoneName == "Knowledge" || $0.zoneName.hasPrefix("Team-")) }
            .sorted { $0.zoneName < $1.zoneName }
    }

    private static func describe(_ error: Error) -> String {
        (error as? CloudError)?.description ?? error.localizedDescription
    }

    let importer: any OldContainerImporting
    let parity: @Sendable () async throws -> ByteParityReport
    let oldContainer: any CloudTransport
    var now: @Sendable () -> Date = { Date() }

    /// The gate, as Settings shows it, with the facts and the report it was judged on.
    func gate() async -> (gate: OldContainerRemovalGate, facts: OldContainerImportFacts?, parity: ByteParityReport?) {
        let facts = try? await importer.facts()
        let report = try? await parity()
        // Read once the old zones are quiet enough to ask: a learner who cannot remove yet needs no network call.
        // A count that cannot be read keeps the gate closed: nothing is known about what only the old zones hold.
        let uncarried: Int? = facts?.finishedAt != nil ? (try? await uncarriedCount()) : 0
        return (OldContainerRemovalGate.evaluate(facts: facts, parity: report, notCarried: uncarried, now: now()), facts, report)
    }

    /// How many ideas, research directions and skills the learner's old zones hold, by their record types.
    func uncarriedCount() async throws -> Int {
        let types = Set(OldContainerRemovalGate.uncarriedEntities.map(\.recordType))
        var count = 0
        for zone in Self.removableZoneNames(try await oldContainer.allZones(in: .private)) {
            var token: CloudChangeToken?
            while true {
                guard case .success(let page) = try await oldContainer.zoneChanges(zone, in: .private, since: token, desiredKeys: []) else { break }
                count += page.modified.filter { types.contains($0.recordType) }.count
                token = page.changeToken
                if !page.moreComing { break }
            }
        }
        return count
    }

    func dialog(facts: OldContainerImportFacts, parity: ByteParityReport) async -> OldContainerRemovalDialog {
        let zones = (try? await oldContainer.allZones(in: .private)).map(Self.removableZoneNames) ?? []
        return OldContainerRemovalDialog(
            lastOldZoneWriteAt: facts.lastOldZoneWriteAt,
            missingTitles: parity.titles(limit: .max).shown,
            waiting: facts.waiting,
            keptRemovals: facts.keptRemovals.count,
            notApplied: facts.notApplied.count,
            zones: zones.map(\.zoneName)
        )
    }

    /// Runs the removal the learner confirmed. The gate is judged again here, then one more import
    /// pass runs; only a quiet pass lets the zones go.
    func remove(confirmed: Bool) async -> Result {
        guard confirmed else { return .notConfirmed }
        let judged = await gate()
        guard judged.gate.isOpen else { return .refused(judged.gate.blockers) }

        let pass: OldContainerFinalPass
        do {
            pass = try await importer.runFinalPass()
        } catch {
            Self.logger.error("The final import pass before the removal failed: \(error.localizedDescription, privacy: .public)")
            return .aborted(.passFailed(Self.describe(error)))
        }
        switch pass {
        case .quiet:
            break
        case .foundWrites(let count):
            // Imported by the pass; the quiet stretch starts over, and nothing is deleted.
            try? await importer.restartQuietWait(at: now())
            Self.logger.notice("The final pass found \(count) old-zone write(s): the removal is aborted and the wait starts again")
            return .aborted(.oldZoneWrites(count: count))
        case .asksQuestion:
            return .aborted(.guardQuestion)
        }

        let zones: [CloudZoneID]
        do {
            zones = Self.removableZoneNames(try await oldContainer.allZones(in: .private))
            guard !zones.isEmpty else {
                try? await importer.recordRemoval(at: now())
                return .removed(zones: [])
            }
            let results = try await oldContainer.modifyZones(saving: [], deleting: zones, in: .private)
            let failed = zones.filter { zone in
                if case .failure? = results.deleted[zone] { return true }
                return results.deleted[zone] == nil
            }
            guard failed.isEmpty else {
                Self.logger.error("Could not delete \(failed.map(\.zoneName).joined(separator: ", "), privacy: .public)")
                return .failed("Could not remove " + failed.map(\.zoneName).joined(separator: ", ") + ".")
            }
        } catch {
            return .failed(Self.describe(error))
        }
        try? await importer.recordRemoval(at: now())
        Self.logger.notice("Removed the old container's zones: \(zones.map(\.zoneName).joined(separator: ", "), privacy: .public)")
        return .removed(zones: zones.map(\.zoneName))
    }
}
