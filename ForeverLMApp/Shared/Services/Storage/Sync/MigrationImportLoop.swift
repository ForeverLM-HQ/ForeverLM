import Foundation
import OSLog

// MARK: - Who imports, and when (docs/cloudkit-schema-design.md §13.6 "Late import", "When it stops", WP16b2)

/// Which Mac runs the importer's pass. One Mac at a time is the importer: the seed-claim holder until
/// `seed.state = complete` (so a seed takeover moves it at once), then the maintenance-lease holder. A Mac
/// that holds neither does not import hourly; it runs a pass from the same base only before it reconciles or
/// takes over (`MigrationCutoverPasses`), as a non-importer.
enum MigrationImporterRole {
    /// `.importer` while this Mac holds the live claim of a seed in progress or the live maintenance lease of a
    /// complete one; nil otherwise.
    static func decide(root: SyncEnvelope, deviceID: String, nowMilliseconds: Int64) -> MigrationImportRole? {
        let state = root.fields["seed"]?.objectValue?["state"]?.stringValue
        switch state {
        case "seeding":
            guard let claim = root.fields["seedClaim"]?.objectValue, claim["device"]?.stringValue == deviceID,
                  let until = claim["leaseUntil"]?.int64Value, until > nowMilliseconds
            else { return nil }
            return .importer
        case "complete":
            guard let holder = MaintenanceLease.holder(in: root), holder.device == deviceID, holder.leaseUntil > nowMilliseconds else { return nil }
            return .importer
        default:
            return nil
        }
    }
}

/// The importer's polling (§13.6): hourly from the seed, daily once seven days have passed with no write to
/// the old zones (`legacyImport.finishedAt`, which only enables "Remove old iCloud data"), weekly after the
/// removal. Any old-zone write clears `finishedAt` again. After the removal a weekly look at the old container
/// continues while it is still in the entitlements, and an old zone a stale build re-created restarts the
/// import: the watermark takes the zones back with no token (so the first pass is a payload walk diffed against
/// the base), `removedAt` and `finishedAt` clear, and the removal is offered again.
actor MigrationImportLoop {
    struct Environment: Sendable {
        let deviceID: String
        /// The personal root as this Mac holds it.
        let root: @Sendable () async throws -> SyncEnvelope?
        /// Whether this Mac holds the library (`ck_activation`): one that holds none never imports.
        let holdsLibrary: @Sendable () async -> Bool
        let lateImport: MigrationLateImport
        let base: any MigrationBaseStore
        let oldContainer: any CloudTransport
        var clock: @Sendable () -> Date = { Date() }
        var sleep: @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
        /// Told after each step, for Settings.
        var report: @Sendable (Step) -> Void = { _ in }
    }

    enum Step: Equatable, Sendable {
        /// This Mac is not the importer (or holds no library, or the root holds no base yet).
        case notImporter
        /// The pass met an outcome that applies nothing: a question waits, the fetch is incomplete, the account
        /// changed, an earlier advance is unacknowledged.
        case held(MigrationPassOutcome)
        case imported(MigrationPassReport)
        /// The old container still has no zone after the removal.
        case zonesStillGone
        /// An old zone is back after the removal: the import restarts.
        case restarted(zones: [String])
    }

    /// How long to wait before looking again at whether this Mac is the importer.
    static let rolePollInterval: TimeInterval = 600
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "MigrationImport")

    private let environment: Environment
    private var task: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?

    init(_ environment: Environment) {
        self.environment = environment
    }

    // MARK: One step

    /// One look: decides the role, and runs a pass or the weekly zone check. Returns the step and how long to
    /// wait before the next.
    func step() async throws -> (step: Step, nextIn: TimeInterval) {
        let env = environment
        guard await env.holdsLibrary(), let root = try await env.root(),
              let role = MigrationImporterRole.decide(root: root, deviceID: env.deviceID, nowMilliseconds: SyncTime.milliseconds(env.clock()))
        else { return (.notImporter, Self.rolePollInterval) }
        guard let watermark = try await env.base.watermark() else { return (.notImporter, Self.rolePollInterval) }

        if watermark.removedAt != nil {
            return try await checkForReappearedZones(watermark)
        }
        let outcome = try await env.lateImport.run(role: role)
        let next = try await env.base.watermark()?.pollInterval ?? MigrationImportWatermark.hour
        switch outcome {
        case .imported(let report): return (.imported(report), next)
        default: return (.held(outcome), min(next, MigrationImportWatermark.hour))
        }
    }

    /// After the removal: a zone that is back restarts the import.
    private func checkForReappearedZones(_ watermark: MigrationImportWatermark) async throws -> (step: Step, nextIn: TimeInterval) {
        let env = environment
        var present: [String] = []
        for database in [CloudDatabaseScope.private, .shared] {
            for zone in try await env.oldContainer.allZones(in: database) {
                let isKnowledge = database == .private && zone.zoneName == CloudKitZoneHome.knowledgeZoneName
                guard isKnowledge || TeamRecord.teamID(fromZoneName: zone.zoneName) != nil else { continue }
                present.append(OldContainerZoneKey.snapshotZone(database: database, zoneID: zone))
            }
        }
        present.sort()
        guard !present.isEmpty else { return (.zonesStillGone, watermark.pollInterval) }

        var restarted = watermark
        restarted.zones = present
        for zone in present { restarted.tokens[zone] = nil }
        restarted.removedAt = nil
        restarted.finishedAt = nil
        restarted.quietSince = nil
        restarted.lastOldWriteAt = SyncTime.milliseconds(env.clock())
        guard try await env.base.advance(MigrationBaseAdvance(entries: [:], watermark: restarted)) else {
            return (.zonesStillGone, MigrationImportWatermark.hour)
        }
        Self.logger.notice("An old zone is back after the removal; the import restarts")
        return (.restarted(zones: present), MigrationImportWatermark.hour)
    }

    // MARK: The loop

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.loop() }
    }

    func stop() {
        task?.cancel()
        task = nil
        sleeper?.cancel()
    }

    /// Cuts the wait short: the learner answered a question, or the Mac's lease changed hands.
    func nudge() {
        sleeper?.cancel()
    }

    private func loop() async {
        let env = environment
        while !Task.isCancelled {
            var wait = Self.rolePollInterval
            do {
                let result = try await step()
                env.report(result.step)
                wait = result.nextIn
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("An import step failed: \(error.localizedDescription, privacy: .public)")
            }
            let sleeping = Task { await env.sleep(wait) }
            sleeper = sleeping
            await sleeping.value
        }
    }
}
