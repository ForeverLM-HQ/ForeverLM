import Foundation

// MARK: - The migration catch-up's decisions (docs/cloudkit-schema-design.md §13.4 step 0, §13.6)

/// What the catch-up knows about an old record this Mac has met before: its row in `sync_metadata` and
/// its pending `sync_changes` row. Foundation only, so the rules below run in a standalone harness.
struct MigrationLocalFacts: Equatable, Sendable {
    /// The change tag of the server record this Mac last saw (`sync_metadata.system_fields`); nil when it
    /// has no row, or one without system fields (a record it never received from the server).
    var syncedChangeTag: String?
    /// A tombstone: the learner deleted the record here (generation 1 never resurrects it).
    var isDeletedLocally = false
    /// `sync_changes.changed_at` of a pending change the drain did not send; nil when there is none.
    var pendingChangedAt: Date?

    static let unknown = MigrationLocalFacts()
}

/// What the catch-up does with one old record (§13.4 step 0).
enum MigrationRecordDecision: Equatable, Sendable {
    /// The change tag is the one this Mac holds: nothing changed in the old world since it last synced.
    case unchanged
    /// Changed in the old world: its differing fields take the server's values.
    case apply
    /// Changed in the old world, but a pending local change is later than the server's
    /// `userModificationDate`: its differing fields keep the local values (generation 1's own
    /// last-writer-wins, kept per record because `sync_changes` names no field, R3-m1). The change is
    /// stamped with `changedAt` when it is seeded or reconciled (§13.4 step 4).
    case keepLocal(changedAt: Date)
    /// A tombstone here: the record is not brought back.
    case skipDeletedLocally
}

enum MigrationCatchUpRules {
    /// Whether the old record changed since this Mac last saw it: its tag differs from the one it holds,
    /// or it holds none (a record it never received, or history cleared at sign-out).
    static func isChanged(serverChangeTag: String?, local: MigrationLocalFacts) -> Bool {
        guard let serverChangeTag, let held = local.syncedChangeTag else { return true }
        return serverChangeTag != held
    }

    /// The per-record rule (§13.4 step 0). A pending change that is strictly later than the old server
    /// record's `userModificationDate` keeps the record's local values; anything else takes the server's.
    static func decide(serverChangeTag: String?, serverModifiedAt: Date, local: MigrationLocalFacts) -> MigrationRecordDecision {
        if local.isDeletedLocally { return .skipDeletedLocally }
        guard isChanged(serverChangeTag: serverChangeTag, local: local) else { return .unchanged }
        if let pending = local.pendingChangedAt, pending > serverModifiedAt { return .keepLocal(changedAt: pending) }
        return .apply
    }

    // MARK: Deletions and the 5% guard

    /// The deletions a walk implies: the names `sync_metadata` holds for the zones it covered that the
    /// walk did not return, split into those applied and those kept because a local change is pending
    /// (a row with a pending local change is kept and logged, §13.4 step 0).
    struct Deletions: Equatable, Sendable {
        var apply: [String] = []
        var keptPending: [String] = []
    }

    /// `held` is every live name this Mac holds in the covered zones, `pending` those with a pending
    /// local change, `returned` the names the walk delivered.
    static func deletions(held: Set<String>, pending: Set<String>, returned: Set<String>) -> Deletions {
        var result = Deletions()
        for name in held.sorted() where !returned.contains(name) {
            if pending.contains(name) { result.keptPending.append(name) } else { result.apply.append(name) }
        }
        return result
    }

    /// The share of the rows `sync_metadata` names above which a walk stops and asks (§13.4 step 0).
    static let guardFraction = 0.05

    /// A walk that would delete more than 5% of the local rows `sync_metadata` names stops before it
    /// applies anything. Another account's library returns none of the names, so every row counts.
    static func tripsGuard(deleting: Int, of held: Int) -> Bool {
        guard held > 0 else { return false }
        return Double(deleting) > Double(held) * guardFraction
    }

    // MARK: Bodies (§13.6)

    /// The cases of a Doc's body when the old record changed.
    enum DocBodyOutcome: Equatable, Sendable {
        /// This Mac holds nothing of its own: the old-world body is applied.
        case takeOldWorld
        /// The two bodies already read alike: nothing to decide.
        case identical
        /// This Mac's edit and the old world's merge cleanly against `document.base.md`: the merged body
        /// is this Mac's (still its own edit), and the old-world Markdown becomes the base.
        case merge
        /// An overlap, differing attachments or site files, or no base to merge against: this Mac's body
        /// stays and the old-world body is saved as a Recovered Doc, so neither side is dropped (R7-m7).
        case keepLocalAndRecover
    }

    static func docBody(
        oldChanged: Bool, bodiesIdentical: Bool, ownEdit: Bool, filesMatch: Bool, mergesCleanly: Bool, hasBase: Bool
    ) -> DocBodyOutcome {
        guard oldChanged else { return .identical }
        if bodiesIdentical { return .identical }
        guard ownEdit else { return .takeOldWorld }
        if hasBase, filesMatch, mergesCleanly { return .merge }
        return .keepLocalAndRecover
    }

    /// A Doc's own-edit test (§13.6, R8-1): the body itself, never a rename, a filing or another field of
    /// its record. `outboxRow` is a `ck_outbox_fields` row on the body field; `markdownDiffersFromBase`
    /// is `document.md` against `document.base.md` and is nil when there is no base. A Doc that keeps a
    /// site counts an undrained row too, until `ck_legacy_bodies.sent_at` says this Mac's seed or
    /// reconcile had its body acknowledged (R8-m3). With no base, the one signal left is generation 1's
    /// own: an undrained row on the record.
    static func docOwnEdit(
        outboxRow: Bool, markdownDiffersFromBase: Bool?, keepsSite: Bool, undrainedRow: Bool, bodySent: Bool
    ) -> Bool {
        if outboxRow { return true }
        guard let differs = markdownDiffersFromBase else { return undrainedRow }
        if differs { return true }
        return keepsSite && undrainedRow && !bodySent
    }

    /// The cases of a notebook's notes (§13.6, "For notes, the old record's change tag decides").
    enum NotesOutcome: Equatable, Sendable {
        /// Nothing to apply; the walk's notes are the base. Local notes that differ are this Mac's edit.
        case unchangedBase
        /// This Mac holds nothing unsent: the old-world notes are applied.
        case takeOldWorld
        /// Local notes differ from the walk's and count as this Mac's edit: they stay, and the walk's
        /// notes are saved as a Recovered Doc.
        case keepLocalAndRecover
    }

    static func notes(oldChanged: Bool, undrainedRow: Bool, hasSyncedHistory: Bool, localEqualsWalk: Bool) -> NotesOutcome {
        guard oldChanged else { return .unchangedBase }
        if localEqualsWalk { return .takeOldWorld }
        if undrainedRow || !hasSyncedHistory { return .keepLocalAndRecover }
        return .takeOldWorld
    }
}
