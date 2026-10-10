import CloudKit
import Foundation
import OSLog

// MARK: - A Doc's or a notebook's notes, decided by the body rule (docs/cloudkit-schema-design.md §13.4 step 0, §13.6)

/// What one catch-up run collects while it applies: the report. A body that lost to this Mac's own edit is
/// kept as a Recovered Doc, made after every record is applied so the notebook it is filed in is there
/// (R7-m7); it is queued durably (`MigrationRecoveryQueue`) in the step that decides it, never held in
/// memory, since the old record's change tag is saved right after and a quit, a cancelled run or a failed
/// later batch would otherwise leave the only copy of the old body in the old container.
final class MigrationCatchUpRunState: @unchecked Sendable {
    var report = MigrationCatchUpReport()
}

/// The Recovered Docs the catch-up owes (`ck_backfill_queue`, kind `migrationRecovery`, one row per body):
/// queued before the record they belong to is marked as received, made by `drain` after every record of a
/// run is in, and drained again by the next run when this one never got there. The id of a Recovered Doc
/// is deterministic, so a row made twice makes one Doc.
enum MigrationRecoveryQueue {
    static let kind = "migrationRecovery"
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "MigrationCatchUp")

    /// Where an old package waits for its Doc (`ck-staging/old-container-recoveries/`).
    static func folder(_ store: KnowledgeStore) -> URL {
        store.satelliteStagingFolder.appendingPathComponent("old-container-recoveries", isDirectory: true)
    }

    /// An old Doc body that lost to this Mac's edit: its package bytes, or the Markdown an early build
    /// carried inline.
    static func enqueueDoc(
        artifactID: String, title: String, notebookID: String?, revision: String, package: Data?, markdown: String, store: KnowledgeStore
    ) throws {
        var payload: [String: Any] = ["kind": "doc", "artifactID": artifactID, "title": title, "revision": revision]
        if let notebookID { payload["notebookID"] = notebookID }
        if let package {
            let name = "\(SyncIdentity.sha256Hex(Data(artifactID.utf8)).prefix(24)).\(revision.prefix(16)).pkg"
            try FileManager.default.createDirectory(at: folder(store), withIntermediateDirectories: true)
            try package.write(to: folder(store).appendingPathComponent(name), options: .atomic)
            payload["file"] = name
        } else {
            payload["markdown"] = markdown
        }
        try insert(target: "doc:\(artifactID):\(revision)", payload: payload, store: store)
    }

    /// A notebook's notes that lost: the text to keep beside the notebook.
    static func enqueueNotes(notebookID: String, text: String, store: KnowledgeStore) throws {
        guard !text.isEmpty else { return }
        try insert(
            target: "notes:\(notebookID):\(SyncIdentity.sha256Hex(Data(text.utf8)))",
            payload: ["kind": "notes", "notebookID": notebookID, "text": text], store: store
        )
    }

    private static func insert(target: String, payload: [String: Any], store: KnowledgeStore) throws {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), as: UTF8.self)
        try store.execute("""
            INSERT INTO ck_backfill_queue (kind, target, payload_json, enqueued_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(kind, target) DO UPDATE SET payload_json = excluded.payload_json
        """, [.text(kind), .text(target), .text(json), .real(Date().timeIntervalSinceReferenceDate)])
    }

    /// Whether a recovery waits, for a run that must not finish with one owed.
    static func pending(store: KnowledgeStore) throws -> Int {
        Int(try store.scalarInteger("SELECT COUNT(*) FROM ck_backfill_queue WHERE kind = ?", [.text(kind)]) ?? 0)
    }

    /// Makes every queued Recovered Doc and removes its row. A row that cannot be made stays, with its
    /// error, and is named in the report.
    static func drain(into report: inout MigrationCatchUpReport, store: KnowledgeStore) throws {
        var rows: [(id: Int64, target: String, json: String)] = []
        try store.query("SELECT id, target, payload_json FROM ck_backfill_queue WHERE kind = ? ORDER BY id", [.text(kind)]) { row in
            if let id = row.integer(0), let target = row.text(1) { rows.append((id, target, row.text(2) ?? "")) }
        }
        for row in rows {
            do {
                guard let object = try JSONSerialization.jsonObject(with: Data(row.json.utf8)) as? [String: Any], let kind = object["kind"] as? String else {
                    throw CocoaError(.coderReadCorrupt)
                }
                switch kind {
                case "doc":
                    guard let artifactID = object["artifactID"] as? String, let title = object["title"] as? String else { throw CocoaError(.coderReadCorrupt) }
                    let package: ArtifactBodyPackage.Decoded
                    if let name = object["file"] as? String {
                        package = try ArtifactBodyPackage.decode(try Data(contentsOf: folder(store).appendingPathComponent(name)))
                    } else if let markdown = object["markdown"] as? String {
                        package = ArtifactBodyPackage.Decoded(
                            markdown: markdown, attachments: [], revision: object["revision"] as? String ?? SyncIdentity.sha256Hex(Data(markdown.utf8))
                        )
                    } else {
                        throw CocoaError(.coderReadCorrupt)
                    }
                    report.recoveredDocs.append(try RecoveredDoc.keepOldWorldPackage(
                        package, artifactID: artifactID, title: title, notebookID: object["notebookID"] as? String, in: store
                    ))
                    if let name = object["file"] as? String { try? FileManager.default.removeItem(at: folder(store).appendingPathComponent(name)) }
                case "notes":
                    guard let notebookID = object["notebookID"] as? String, let text = object["text"] as? String else { throw CocoaError(.coderReadCorrupt) }
                    if !text.isEmpty { report.recoveredDocs.append(try RecoveredDoc.keepNotes(text, notebookID: notebookID, in: store)) }
                default:
                    throw CocoaError(.coderReadCorrupt)
                }
                try store.execute("DELETE FROM ck_backfill_queue WHERE id = ?", [.integer(row.id)])
            } catch {
                report.failed.append("recovery:\(row.target)")
                logger.error("Could not make the Recovered Doc \(row.target, privacy: .private): \(error.localizedDescription, privacy: .public)")
                try store.execute("UPDATE ck_backfill_queue SET attempts = attempts + 1, last_error = ? WHERE id = ?", [.text(error.localizedDescription), .integer(row.id)])
            }
        }
    }
}

enum MigrationBodies {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "MigrationCatchUp")

    // MARK: This Mac's own edit (§13.6, R8-1, R8-m3): reused by WP16's reconcile and WP16b's body rule

    /// Whether this Mac holds an edit of the Doc's body it has not sent: a change to the body itself,
    /// never a rename, a filing or another field of its record. Today's `sync_changes` row alone is no
    /// edit, since generation 1 marks a Doc changed for all of those.
    static func docOwnEdit(_ artifactID: String, store: KnowledgeStore) throws -> Bool {
        let outboxRow = try store.scalarInteger(
            "SELECT EXISTS(SELECT 1 FROM ck_outbox_fields WHERE source_table = 'global_artifacts' AND local_key = ? AND \"column\" = 'body_ref')",
            [.text(artifactID)]
        ) == 1
        let mine = try store.loadArtifactMarkdownForSync(artifactID)
        let base = try store.loadArtifactBaseMarkdown(artifactID)
        let differs: Bool? = base.flatMap { base in mine.map { $0 != base } }
        return MigrationCatchUpRules.docOwnEdit(
            outboxRow: outboxRow, markdownDiffersFromBase: differs, keepsSite: store.hasLocalSite(artifactID),
            undrainedRow: try store.hasPendingSyncChange(entity: .artifact, logicalKey: artifactID),
            bodySent: try bodySent(type: .artifact, wireID: artifactID, store: store)
        )
    }

    /// Whether this Mac's seed or reconcile had the body's upload acknowledged (`ck_legacy_bodies.sent_at`,
    /// which the cutover's satellite pass writes, `CutoverSatellites`).
    static func bodySent(type: SyncRecordType, wireID: String, store: KnowledgeStore) throws -> Bool {
        try store.scalarInteger(
            "SELECT EXISTS(SELECT 1 FROM ck_legacy_bodies WHERE record_type = ? AND wire_id = ? AND field = 'body' AND sent_at IS NOT NULL)",
            [.text(type.rawValue), .text(wireID)]
        ) == 1
    }

    // MARK: A Doc

    /// What the body rule says about an old Doc, and the pieces its effects need.
    struct DocDecision {
        let payload: CloudKitArtifactPayload
        let outcome: MigrationCatchUpRules.DocBodyOutcome
        let theirs: ArtifactBodyPackage.Decoded
        let merged: String?
        let mine: String
    }

    /// The body rule for a Doc (§13.6) against what this Mac holds; nil when the rule does not apply
    /// (card decks, readings, a team's Docs, a Doc with no body here or no body in the old record), and
    /// generation 1's apply stands.
    static func decideDoc(_ planned: MigrationPlannedRecord, store: KnowledgeStore) throws -> DocDecision? {
        guard !planned.home.isTeamZone, case .artifact(let payload)? = planned.decoded?.payload,
              !payload.artifact.isCardDeck, !payload.artifact.isMnemonicReading,
              let theirs = try theirBody(planned, payload: payload) else { return nil }
        let artifactID = payload.artifact.id
        guard let mine = try store.loadArtifactMarkdownForSync(artifactID), let own = try store.loadArtifactBodyPackageForSync(artifactID) else { return nil }
        let mineDecoded = try ArtifactBodyPackage.decode(own.data)
        let filesMatch = mineDecoded.attachments == theirs.attachments && mineDecoded.siteFiles == theirs.siteFiles
        let identical = own.revision == payload.bodyRevision || (mine == theirs.markdown && filesMatch)
        let ownEdit = try identical ? false : docOwnEdit(artifactID, store: store)
        let base = try store.loadArtifactBaseMarkdown(artifactID)
        var merged: String?
        if let base, case .merged(let text) = ArtifactThreeWayMerge.merge(base: base, mine: mine, theirs: theirs.markdown) { merged = text }
        let outcome = MigrationCatchUpRules.docBody(
            oldChanged: true, bodiesIdentical: identical, ownEdit: ownEdit, filesMatch: filesMatch, mergesCleanly: merged != nil, hasBase: base != nil
        )
        return DocDecision(payload: payload, outcome: outcome, theirs: theirs, merged: merged, mine: mine)
    }

    /// An old Artifact applied. A Doc's Markdown is decided by the body rule, whatever the stamps: this
    /// Mac's own edit stays (merged three ways against `document.base.md` when both packages hold the
    /// same attachments and site files, else beside a Recovered Doc), and a body with no edit of its own
    /// takes the old world's. Card decks, readings and a team's Docs keep generation 1's apply.
    static func applyArtifact(
        _ planned: MigrationPlannedRecord, ck: CKRecord, descriptor: CloudKitRecordDescriptor, store: KnowledgeStore, state: MigrationCatchUpRunState
    ) throws -> CloudKitAppliedRecord {
        func standard() throws -> CloudKitAppliedRecord {
            try CloudKitRecordMapper.applyFetched(record: ck, descriptor: descriptor, home: planned.home, to: store)
        }
        guard let decision = try decideDoc(planned, store: store) else { return try standard() }
        switch decision.outcome {
        case .takeOldWorld, .identical:
            return try standard()
        case .merge, .keepLocalAndRecover:
            let applied = try recordOnly(payload: decision.payload, descriptor: descriptor, store: store)
            try keepBody(decision, planned: planned, store: store, state: state)
            return applied
        }
    }

    /// An Artifact kept local by the per-record rule: its other fields stay, and its body is still decided
    /// by the body rule (a Doc renamed here, whose body the old world changed, takes the old body).
    static func keepArtifactLocal(_ planned: MigrationPlannedRecord, store: KnowledgeStore, state: MigrationCatchUpRunState) throws {
        guard let decision = try decideDoc(planned, store: store) else { return }
        switch decision.outcome {
        case .identical:
            return
        case .takeOldWorld:
            try store.withoutSyncTracking {
                if let bytes = planned.decoded?.bodyPackage {
                    _ = try store.saveArtifactBodyPackageFromSync(bytes, artifactID: decision.payload.artifact.id, expectedRevision: decision.payload.bodyRevision)
                } else {
                    try store.saveArtifactMarkdownFromSync(decision.theirs.markdown, artifactID: decision.payload.artifact.id)
                }
            }
        case .merge, .keepLocalAndRecover:
            try keepBody(decision, planned: planned, store: store, state: state)
        }
    }

    /// The effects of the two outcomes that keep this Mac's body.
    private static func keepBody(_ decision: DocDecision, planned: MigrationPlannedRecord, store: KnowledgeStore, state: MigrationCatchUpRunState) throws {
        let artifactID = decision.payload.artifact.id
        if decision.outcome == .merge, let merged = decision.merged {
            if merged != decision.mine { try store.writeArtifactMarkdown(merged, artifactID: artifactID) }
            try store.saveArtifactBaseMarkdown(decision.theirs.markdown, artifactID: artifactID)
            state.report.mergedDocs.append(artifactID)
        } else {
            try MigrationRecoveryQueue.enqueueDoc(
                artifactID: artifactID, title: decision.payload.artifact.title, notebookID: decision.payload.artifact.homeNotebookID,
                revision: decision.theirs.revision, package: planned.decoded?.bodyPackage, markdown: decision.theirs.markdown, store: store
            )
        }
    }

    /// The old record's body: its package (`payloadAsset`), or the Markdown an early build carried inline.
    private static func theirBody(_ planned: MigrationPlannedRecord, payload: CloudKitArtifactPayload) throws -> ArtifactBodyPackage.Decoded? {
        if let package = planned.decoded?.bodyPackage { return try ArtifactBodyPackage.decode(package, expectedRevision: payload.bodyRevision) }
        guard let markdown = payload.markdown else { return nil }
        return ArtifactBodyPackage.Decoded(markdown: markdown, attachments: [], revision: SyncIdentity.sha256Hex(Data(markdown.utf8)))
    }

    /// The Artifact's record, without its body (a merged or kept body is not overwritten).
    private static func recordOnly(payload: CloudKitArtifactPayload, descriptor: CloudKitRecordDescriptor, store: KnowledgeStore) throws -> CloudKitAppliedRecord {
        try store.withoutSyncTracking {
            try store.saveArtifactRecord(payload.artifact)
            try store.saveArtifactWalkthroughFromSync(artifactID: payload.artifact.id, walkthrough: payload.walkthrough)
        }
        return CloudKitAppliedRecord(entity: .artifact, logicalKey: payload.artifact.id, userModificationDate: descriptor.userModificationDate, requiresRepublish: false)
    }

    // MARK: A notebook's notes

    /// Whether a LearningGoal record is a notebook, by the kind this Mac classified it as or, before the
    /// activation has, by the shape of its payload (b1).
    static func isNotebook(_ payload: CloudKitLearningGoalPayload, store: KnowledgeStore) throws -> Bool {
        let goal = payload.goal
        let kind = try store.scalarText("SELECT entity_kind FROM learning_goals WHERE id = ?", [.text(goal.id)])
            ?? LearningGoalEntityKind.kind(kind: goal.kind, parentNotebookID: goal.parentNotebookID, endAt: goal.endAt.timeIntervalSinceReferenceDate)
        return kind == LearningGoalEntityKind.notebook
    }

    /// The notes case of §13.6 for a notebook the walk returned: what happens to this Mac's notes and the
    /// old record's.
    static func notesOutcome(_ planned: MigrationPlannedRecord, payload: CloudKitLearningGoalPayload, store: KnowledgeStore) throws -> (MigrationCatchUpRules.NotesOutcome, local: String?)? {
        guard !planned.home.isTeamZone, try isNotebook(payload, store: store),
              let row = try? store.scalarText("SELECT COALESCE(notes, '') FROM learning_goals WHERE id = ?", [.text(payload.goal.id)]) else { return nil }
        let outcome = MigrationCatchUpRules.notes(
            oldChanged: planned.decision != .unchanged,
            undrainedRow: planned.local.pendingChangedAt != nil,
            hasSyncedHistory: planned.local.syncedChangeTag != nil,
            localEqualsWalk: NotesDoc.text(row) == NotesDoc.text(payload.goal.notes)
        )
        return (outcome, row)
    }

    /// A notebook applied: its notes are decided apart from the record's other fields, so a local note
    /// that counts as this Mac's edit survives the apply.
    static func applyLearningGoal(
        _ planned: MigrationPlannedRecord, ck: CKRecord, descriptor: CloudKitRecordDescriptor, store: KnowledgeStore, state: MigrationCatchUpRunState
    ) throws -> CloudKitAppliedRecord {
        guard case .learningGoal(let payload)? = planned.decoded?.payload, let notes = try notesOutcome(planned, payload: payload, store: store) else {
            return try CloudKitRecordMapper.applyFetched(record: ck, descriptor: descriptor, home: planned.home, to: store)
        }
        // The old notes are queued before the apply replaces this Mac's: the recovery exists first.
        if notes.0 == .keepLocalAndRecover {
            try MigrationRecoveryQueue.enqueueNotes(notebookID: payload.goal.id, text: NotesDoc.text(payload.goal.notes), store: store)
        }
        let applied = try CloudKitRecordMapper.applyFetched(record: ck, descriptor: descriptor, home: planned.home, to: store)
        if notes.0 == .keepLocalAndRecover {
            try store.execute("UPDATE learning_goals SET notes = ? WHERE id = ?", [.text((notes.local ?? "").isEmpty ? nil : notes.local), .text(payload.goal.id)])
        }
        return applied
    }

    /// A notebook whose pending local change won the per-record rule: its notes may still differ from the
    /// old world's, and then stay beside a Recovered Doc.
    static func keepLearningGoalLocal(_ planned: MigrationPlannedRecord, store: KnowledgeStore, state: MigrationCatchUpRunState) throws {
        guard case .learningGoal(let payload)? = planned.decoded?.payload,
              let notes = try notesOutcome(planned, payload: payload, store: store), notes.0 == .keepLocalAndRecover else { return }
        try MigrationRecoveryQueue.enqueueNotes(notebookID: payload.goal.id, text: NotesDoc.text(payload.goal.notes), store: store)
    }

    /// The notes of every notebook the walk returned, kept as its notes base, by wire id, whatever its
    /// change tag and whether or not an undrained row exists (§13.4 step 0, R8-1).
    static func saveNotesBase(_ planned: MigrationPlannedRecord, store: KnowledgeStore, state: MigrationCatchUpRunState) throws {
        guard !planned.home.isTeamZone, case .learningGoal(let payload)? = planned.decoded?.payload, try isNotebook(payload, store: store) else { return }
        try NotesBase.saveLegacy(NotesDoc.text(payload.goal.notes), notebookID: payload.goal.id, connection: store)
        state.report.notesBases += 1
    }

    // MARK: Recovered Docs, after every record is in

    static func makeRecoveries(_ state: MigrationCatchUpRunState, store: KnowledgeStore) throws {
        try MigrationRecoveryQueue.drain(into: &state.report, store: store)
    }

    // MARK: Packages staged for the seed (R8-m6)

    /// The old package of every Doc this Mac cannot reproduce (a web-encoded one, say), kept for the
    /// seed's P1 and P5 so nothing is fetched by name after the walk. Staged after the apply, so a Doc
    /// that took the old body is compared with the revision its own encoding now gives.
    static func stagePackage(_ planned: MigrationPlannedRecord, store: KnowledgeStore, state: MigrationCatchUpRunState) throws {
        guard !planned.home.isTeamZone, case .artifact(let payload)? = planned.decoded?.payload, let revision = payload.bodyRevision,
              let package = planned.decoded?.bodyPackage, let own = try store.loadArtifactBodyPackageForSync(payload.artifact.id),
              own.revision != revision else { return }
        try OldContainerStagedPackages.stage(package, artifactID: payload.artifact.id, revision: revision, store: store)
        state.report.stagedPackages += 1
    }
}

/// The old packages the walk staged for the seed (`ck-staging/old-container-docs/`), found by the Doc's id and
/// the old record's `bodyRevision`. The seed uploads one when it decodes to this Mac's body (§13.4 P5) and
/// deletes them all once its seed or reconcile is done.
enum OldContainerStagedPackages {
    static func folder(_ store: KnowledgeStore) -> URL {
        store.satelliteStagingFolder.appendingPathComponent("old-container-docs", isDirectory: true)
    }

    static func url(artifactID: String, revision: String, store: KnowledgeStore) -> URL {
        folder(store).appendingPathComponent("\(SyncIdentity.sha256Hex(Data(artifactID.utf8)).prefix(24)).\(revision.prefix(16)).pkg")
    }

    static func stage(_ package: Data, artifactID: String, revision: String, store: KnowledgeStore) throws {
        try FileManager.default.createDirectory(at: folder(store), withIntermediateDirectories: true)
        try package.write(to: url(artifactID: artifactID, revision: revision, store: store), options: .atomic)
    }

    static func staged(artifactID: String, revision: String, store: KnowledgeStore) -> Data? {
        try? Data(contentsOf: url(artifactID: artifactID, revision: revision, store: store))
    }

    static func removeAll(store: KnowledgeStore) {
        try? FileManager.default.removeItem(at: folder(store))
    }
}
