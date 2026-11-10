// MARK: - Who seeds (docs/cloudkit-schema-design.md §13.4 step 1, §13.5)

/// What the personal root says about the seed (`seed`, `seedClaim`, §3.5.1).
struct CutoverRootState: Equatable, Sendable {
    var state: String?
    var metadataCompleteAt: Int64?
    var claimDevice: String?
    var claimLeaseUntil: Int64?

    init(state: String? = nil, metadataCompleteAt: Int64? = nil, claimDevice: String? = nil, claimLeaseUntil: Int64? = nil) {
        self.state = state
        self.metadataCompleteAt = metadataCompleteAt
        self.claimDevice = claimDevice
        self.claimLeaseUntil = claimLeaseUntil
    }

    init(root: SyncEnvelope) {
        let seed = root.fields["seed"]?.objectValue ?? [:]
        state = seed["state"]?.stringValue
        metadataCompleteAt = seed["metadataCompleteAt"]?.int64Value
        let claim = root.fields["seedClaim"]?.objectValue
        claimDevice = claim?["device"]?.stringValue
        claimLeaseUntil = claim?["leaseUntil"]?.int64Value
    }

    func claimIsLive(at now: Int64) -> Bool {
        guard claimDevice != nil, let until = claimLeaseUntil else { return false }
        return until > now
    }
}

/// What a Mac does about the seed once it holds the root (§13.4 step 1).
enum CutoverClaimDecision: Equatable, Sendable {
    /// Only a Mac that holds the library ever claims.
    case noLibrary
    /// This Mac is the seeder relaunching: it renews the claim and continues its cursor.
    case resume
    /// `pending`: claim by a compare-and-set save and seed, in reconcile mode against whatever a Mac with no
    /// library wrote meanwhile.
    case claim
    /// Another Mac's claim is live and the metadata is not complete: wait and look again.
    case wait(holder: String, leaseUntil: Int64)
    /// `seeding` with an expired claim that is not this Mac's: take it over, reconciling against whatever the
    /// old holder already sent, and continue from this Mac's own cursor.
    case takeOver
    /// The seed's metadata is complete (or the seed is): this Mac reconciles at once, and runs its own
    /// cursor for satellites when it can take the claim.
    case secondMac

    static func decide(_ root: CutoverRootState, me: String, holdsLibrary: Bool, now: Int64) -> CutoverClaimDecision {
        guard holdsLibrary else { return .noLibrary }
        if root.state == "seeding", root.claimDevice == me { return .resume }
        if root.metadataCompleteAt != nil || root.state == "complete" { return .secondMac }
        switch root.state {
        case "pending":
            return .claim
        case "seeding":
            if root.claimIsLive(at: now), let holder = root.claimDevice, let until = root.claimLeaseUntil {
                return .wait(holder: holder, leaseUntil: until)
            }
            return .takeOver
        default:
            // A root with no seed state (a build that never wrote one): another device is still making it.
            return .wait(holder: "", leaseUntil: now)
        }
    }
}
