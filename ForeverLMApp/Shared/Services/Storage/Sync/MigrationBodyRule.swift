import Foundation

// MARK: - A body is decided by the base, never by stamps (docs/cloudkit-schema-design.md §13.6)

/// What a pass does with a Doc's or a Notes Doc's body when the old record's body differs from the base's.
/// Every pass runs it, a refresh's too, so B's import pass, the importer and a reconcile meeting the same
/// difference make one record between them (a create of an id that exists is skipped).
enum MigrationBodyRule {
    enum Outcome: Equatable, Sendable {
        /// Nothing to apply: the old body is the base's, or the new world already carries it.
        case nothing
        /// The new world has not touched the body since the base, and this Mac holds no edit of its own:
        /// the old-world body is applied, however old its stamp.
        case apply
        /// Both worlds changed it: the new world's body stays, and the old one is saved as the Recovered
        /// Doc `recovered:<artifactID>:<hash>`.
        case recover
    }

    /// - Parameters:
    ///   - oldHash: the hash of the body the old record gives now (a Doc's `bodyRevision`, a Notes body's
    ///     encoded-text hash); nil when the old record gives none this time (an unchanged Doc's package is
    ///     never fetched, and a body is never cleared on that account).
    ///   - baseHash: what the base holds for the body; nil when the base never listed it.
    ///   - replicaHash: the body hash of the server's copy; nil when it holds none.
    ///   - pendingHash: the body hash of this Mac's pending patch; nil when it carries none.
    ///   - ownEdit: this Mac holds an edit of the body itself that it has not sent (`MigrationBodyEditProbe`).
    static func decide(oldHash: String?, baseHash: String?, replicaHash: String?, pendingHash: String?, ownEdit: Bool) -> Outcome {
        guard let oldHash else { return .nothing }
        if oldHash == baseHash { return .nothing }
        if oldHash == replicaHash || oldHash == pendingHash { return .nothing }
        let untouched = replicaHash == baseHash && (pendingHash == nil || pendingHash == baseHash)
        if untouched && !ownEdit { return .apply }
        return .recover
    }

    static func recoveredID(artifactID: String, hash: String) -> String {
        "recovered:\(artifactID):\(hash)"
    }
}

/// Whether this Mac holds an edit of a body it has not sent (§13.6, R7-3, R8-1, R8-m3): a change to the
/// body itself, never a rename, a filing, archiving or relinking of its record, which generation 1 also
/// marks as changed. Implemented on the store by `StoreMigrationBodyEditProbe`.
protocol MigrationBodyEditProbe: Sendable {
    /// A Doc: a `ck_outbox_fields` row on the body field, a `document.md` that differs from
    /// `document.base.md`, or, for a Doc that keeps a site, an undrained `sync_changes` row until
    /// `ck_legacy_bodies.sent_at` says its upload was acknowledged.
    func docHoldsOwnEdit(artifactID: String) throws -> Bool
    /// A Notes Doc: a `ck_outbox_fields` row on the notes, or notes that differ from the notes base (the
    /// notes of the old notebook record the catch-up's walk returned, or the acknowledged notes once one
    /// was uploaded). A notebook with no notes base has none to differ from.
    func notesHoldOwnEdit(notebookID: String) throws -> Bool
}
