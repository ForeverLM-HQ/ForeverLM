import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// Late import (docs/cloudkit-schema-design.md §13.6, WP16b): after the seed, an old build's writes reach the
/// new world field by field, as patches stamped with the old records' dates. The old world is another Mac's
/// generation-1 store writing a `FakeCloudKit` old container; the seed is stood in for by mapping that world
/// into the replica, the base and the manifest (`MigrationImportRig`). The decisions themselves are pinned in
/// `MigrationImportPlannerTests` and the shards in `MigrationBaseTests`; this suite pins what a pass does with
/// them: what it fetches, queues, sends, asks, lists and advances.
@Suite("Migration late import")
struct MigrationLateImportTests {
    private typealias Rig = MigrationImportRig

    /// A moment later than the seed, so an old-world edit is stamped after the seeded value.
    private static func later() async throws { try await Task.sleep(nanoseconds: 30_000_000) }

    private static func entryID(_ notebookID: String, _ sourceID: String) -> String {
        SyncIdentity.entryID(containerID: notebookID, itemKind: "source", itemID: sourceID)
    }

    // MARK: Field by field

    @Test("An old build's rename reaches a seeded notebook as a patch stamped with the old date, and is sent and settled")
    func renameIsAPatch() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let notebook = try rig.notebook("Mitochondria")
        try await rig.seed()
        try await Self.later()
        try rig.rename(notebook, to: "Mitochondria and more")

        let report = try await rig.imported()
        #expect(report.changed == 1 && report.sawOldWrite && report.failed.isEmpty, "\(report)")
        let patch = try #require(try rig.patch(.notebook, notebook))
        #expect(patch.changes["title"]?.stringValue?.contains("Mitochondria and more") == true)
        guard case .value(let stamp)? = patch.stamps["title"] else { Issue.record("title has no stamp"); return }
        #expect(stamp.deviceID == SyncIdentity.legacyDeviceID && stamp.policy == .lastWriter, "the migration's device, the schema's letter")
        #expect(try rig.localTitle(notebook)?.contains("Mitochondria and more") == true, "projected under the guard")
        #expect(try rig.store.scalarInteger("SELECT COUNT(*) FROM ck_outbox_fields WHERE source_table = 'learning_goals'") == 0, "so the triggers queued nothing a second time")

        let sent = try await rig.sendPatches()
        #expect(sent.contains { $0.recordType == .notebook && $0.wireID == notebook }, "the Mac sends the patches it holds")
        #expect(try rig.patchCount() == 0, "and the acknowledgement settles them")
        let held = try #require(try rig.store.replica.record(zoneKey: Rig.N.libraryZoneKey, recordType: SyncRecordType.notebook.rawValue, wireID: notebook))
        #expect(try SyncEnvelope(storedPayload: held.payload).fields["title"]?.stringValue?.contains("Mitochondria and more") == true)
    }

    @Test("A later new-world edit is never reverted by an old-world change")
    func newWorldEditWins() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let notebook = try rig.notebook("Mitochondria")
        try await rig.seed()
        try await Self.later()
        try rig.rename(notebook, to: "Old world title")
        try rig.newWorldEdit(.notebook, notebook, ["title": "New world title"], ms: SyncTime.milliseconds(Date().addingTimeInterval(86_400)))

        try await rig.imported()
        #expect(try rig.patch(.notebook, notebook)?.changes["title"] == nil, "the newer stamp stands")
        #expect(try rig.localTitle(notebook) == "New world title")
    }

    @Test("This Mac's own unsent edit is not overwritten by a patch of an older old-world change")
    func localEditSurvivesProjection() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let notebook = try rig.notebook("Mitochondria")
        try await rig.seed()
        try await Self.later()
        try rig.rename(notebook, to: "Old world title")
        try await Self.later()
        try rig.store.execute("UPDATE learning_goals SET title = 'Local title', updated_at = ? WHERE id = ?", [.real(Date().timeIntervalSinceReferenceDate), .text(notebook)])

        try await rig.imported()
        #expect(try rig.localTitle(notebook) == "Local title", "the patch is merged with the unsent edit as an inbound version would be")
    }

    // MARK: Created whole

    @Test("A turn appended to a seeded chat is created whole, listed for its delta, and projected")
    func turnIsCreated() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let notebook = try rig.notebook("Chats")
        try rig.chat("chat-1", in: notebook)
        try await rig.seed()
        try await Self.later()
        try rig.addTurn(to: "chat-1", question: "What pumps the protons?")

        let report = try await rig.imported()
        #expect(report.creates == 1, "\(report)")
        #expect(try rig.store.scalarInteger("SELECT COUNT(*) FROM ck_patches WHERE record_type = 'Exchange'") == 1)
        #expect(try rig.manifestPending() == 1, "the create waits in ck_manifest_pending for its delta")
        #expect(try rig.store.scalarInteger("SELECT COUNT(*) FROM review_exchanges WHERE session_id = 'chat-1'") == 2, "the new turn is in the chat's rows")
    }

    @Test("A source filed into a seeded notebook is created as an Entry; one the new world deleted is not created again")
    func filingIsCreated() async throws {
        for deleted in [false, true] {
            let rig = try Rig()
            defer { rig.cleanUp() }
            let notebook = try rig.notebook("Filing")
            try rig.source("src-1")
            try await rig.seed()
            let entry = Self.entryID(notebook, "src-1")
            if deleted { rig.ledger.addToManifest([MigrationRecordKey(.entry, entry)]) }
            try await Self.later()
            try rig.file("src-1", into: notebook)

            let report = try await rig.imported()
            if deleted {
                #expect(try rig.patch(.entry, entry) == nil && report.skipped >= 1, "the delete wins: \(report)")
            } else {
                let patch = try #require(try rig.patch(.entry, entry))
                #expect(patch.changes["state"]?.stringValue == "active" && patch.changes["itemID"]?.stringValue == "src-1", "created whole")
            }
        }
    }

    @Test("A source taken out of a seeded notebook flips its Entry to removed, when the guard is lifted")
    func removalFlips() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let notebook = try rig.notebook("Filing")
        try rig.source("src-1")
        try rig.file("src-1", into: notebook)
        try await rig.seed()
        try await Self.later()
        try rig.unfile("src-1", from: notebook)

        let report = try await rig.imported(guardLifted: true)
        #expect(report.removals == 1, "\(report)")
        let patch = try #require(try rig.patch(.entry, Self.entryID(notebook, "src-1")))
        #expect(patch.changes["state"]?.stringValue == "removed", "an Entry flips, it is never deleted")
    }

    // MARK: The 5% guard

    @Test("A pass that would remove more than 5% asks, applies nothing and leaves the base; Apply runs it once")
    func guardApply() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let notebook = try rig.notebook("Filing")
        try rig.source("src-1")
        try rig.file("src-1", into: notebook)
        try await rig.seed()
        let before = try #require(rig.base.current)
        try await Self.later()
        try rig.unfile("src-1", from: notebook)

        guard case .guardTripped(let question) = try await rig.run() else { Issue.record("the guard did not trip"); return }
        #expect(question.removing == 1 && question.of > 1 && question.answer == nil)
        #expect(try rig.patchCount() == 0 && rig.base.advances == 0 && rig.base.current == before, "nothing applied, the base where it was")
        #expect(try await rig.run() == .waitingForQuestion, "the pass waits for the learner, whichever Mac runs it")

        try await rig.local.perform { try MigrationImportState.answer(.apply, $0.connection) }
        let report = try await rig.imported()
        #expect(report.removals == 1)
        #expect(try rig.patch(.entry, Self.entryID(notebook, "src-1"))?.changes["state"]?.stringValue == "removed")
        #expect(try await rig.local.perform { try MigrationImportState.guardQuestion($0.connection) } == nil, "the answer is consumed")
    }

    @Test("Keep applies the rest, lists the removal as kept and advances the base past it")
    func guardKeep() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let notebook = try rig.notebook("Filing")
        try rig.source("src-1")
        try rig.file("src-1", into: notebook)
        try await rig.seed()
        try await Self.later()
        try rig.unfile("src-1", from: notebook)
        try rig.rename(notebook, to: "Renamed meanwhile")

        guard case .guardTripped = try await rig.run() else { Issue.record("the guard did not trip"); return }
        try await rig.local.perform { try MigrationImportState.answer(.keep, $0.connection) }
        let report = try await rig.imported()
        #expect(report.removals == 0 && report.kept >= 1, "\(report)")
        #expect(try rig.patch(.entry, Self.entryID(notebook, "src-1")) == nil, "the Entry stays")
        #expect(try rig.patch(.notebook, notebook)?.changes["title"] != nil, "the rest of the pass applies")
        let kept = try await rig.local.perform { try MigrationImportState.kept($0.connection) }
        #expect(kept.contains { $0.reason == .keptByAnswer && $0.type == "Entry" })

        try await rig.sendPatches()
        _ = try await rig.imported()
        let entry = try #require(rig.base.entry("Knowledge/" + (try rig.goalRecordName(notebook))))
        #expect(entry.records.keys.contains { $0.hasPrefix("Entry:") } == false, "the base moved past the kept removal")
    }

    // MARK: The base

    @Test("The importer moves the base only once its patches are acknowledged; any other Mac writes the same patches and leaves it")
    func bookkeeping() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let notebook = try rig.notebook("Mitochondria")
        try await rig.seed()
        let before = try #require(rig.base.current)
        try await Self.later()
        try rig.rename(notebook, to: "Renamed")

        let report = try await rig.imported()
        #expect(report.advanced == false && rig.base.advances == 0, "the patches are still on their way")
        #expect(try await rig.run() == .waitingForAcknowledgement, "no new pass starts while they are")

        try await rig.sendPatches()
        try await rig.imported()
        #expect(rig.base.advances >= 1)
        let key = MigrationBaseShards.entryKey(zone: Rig.zoneName, recordName: try rig.goalRecordName(notebook))
        let hashed = try #require(rig.base.entry(key)).records["Notebook:\(notebook)"]?.hashes["title"]
        #expect(hashed != nil && hashed != "")
        #expect(rig.base.current?.tokens[Rig.zoneName] != before.tokens[Rig.zoneName], "and the token advanced past what the pass read")
    }

    @Test("A Mac that is not the importer writes the patches and never touches the base or keeps a journal")
    func otherMac() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let notebook = try rig.notebook("Mitochondria")
        try await rig.seed()
        let before = try #require(rig.base.current)
        try await Self.later()
        try rig.rename(notebook, to: "Renamed")

        try await rig.imported(.other)
        #expect(try rig.patch(.notebook, notebook)?.changes["title"] != nil)
        #expect(rig.base.advances == 0 && rig.base.current == before)
        #expect(try await rig.local.perform { try MigrationImportState.journal($0.connection) } == nil)
        try await rig.imported(.other)
        #expect(try rig.patchCount() == 1, "a second pass writes the same patch, so the pass is idempotent")
    }

    @Test("A root that changed under the advance leaves the journal for the next pass")
    func lostAdvance() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let notebook = try rig.notebook("Mitochondria")
        try await rig.seed()
        try await Self.later()
        try rig.rename(notebook, to: "Renamed")
        try await rig.imported()
        try await rig.sendPatches()

        rig.base.losesNextAdvance = true
        #expect(try await rig.run() == .waitingForAcknowledgement)
        #expect(try await rig.local.perform { try MigrationImportState.journal($0.connection) } != nil)
        try await rig.imported()
        #expect(rig.base.advances == 1, "the next pass finishes it")
    }

    @Test("Seven quiet days finish the import, and the importer keeps polling")
    func quiet() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        _ = try rig.notebook("Mitochondria")
        try await rig.seed()
        try await rig.imported()
        #expect(rig.base.current?.quietSince != nil && rig.base.current?.finishedAt == nil)
        rig.clock.advance(8 * 86_400)
        try await rig.imported()
        #expect(rig.base.current?.finishedAt != nil, "no old-zone write for seven days")
        try await Self.later()
        try rig.rename(try rig.notebook("Another"), to: "Written after")
        try await rig.imported()
        try await rig.sendPatches()
        try await rig.imported()
        #expect(rig.base.current?.finishedAt == nil, "any old-zone write clears it again, once its patches are acknowledged")
    }

    // MARK: When a pass runs

    @Test("No pass runs before this Mac's fetch of Library and Catalog is complete, or before the root holds a base")
    func gate() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        _ = try rig.notebook("Mitochondria")
        #expect(try await rig.run() == .notReady, "no base on the root yet")
        try await rig.seed()
        var library = try #require(try rig.store.replica.zone(key: Rig.N.libraryZoneKey))
        library.lastCompletePassAt = nil
        try rig.store.replica.upsertZone(library)
        #expect(try await rig.run() == .notReady, "a record that has not arrived must never be taken for absent")
    }

    @Test("A missing old zone ends its import and deletes nothing")
    func missingZone() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        _ = try rig.notebook("Mitochondria")
        try await rig.seed()
        rig.server.deleteZone(Rig.zoneName, owner: Rig.learner, container: FakeCloudKit.legacyContainer, reason: .purged)
        try await rig.imported()
        #expect(try rig.patchCount() == 0)
        try await rig.sendPatches()
        try await rig.imported()
        #expect(rig.base.current?.zones.isEmpty == true, "the zone leaves the import")
    }

    @Test("An expired token is a walk from nil diffed against the base: unchanged records are no change, a changed one applies")
    func expiredToken() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let kept = try rig.notebook("Unchanged")
        let renamed = try rig.notebook("Mitochondria")
        try await rig.seed()
        try await Self.later()
        try rig.rename(renamed, to: "Renamed")
        rig.server.expireZoneChangeTokens(zone: Rig.zoneName, owner: Rig.learner, container: FakeCloudKit.legacyContainer)

        let report = try await rig.imported()
        #expect(report.changed == 1, "\(report)")
        #expect(try rig.patch(.notebook, renamed)?.changes["title"] != nil && rig.patch(.notebook, kept) == nil)
    }

    // MARK: Manifest deltas

    @Test("A pass lists its creates in a delta once they are acknowledged, so a record deleted later stays deleted")
    func deltaIsWritten() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let notebook = try rig.notebook("Chats")
        try rig.chat("chat-1", in: notebook)
        try await rig.seed()
        try await Self.later()
        try rig.addTurn(to: "chat-1", question: "Second")

        try await rig.imported()
        #expect(rig.ledger.deltas.isEmpty, "nothing is listed before the server has the record")
        try await rig.sendPatches()
        try await rig.imported()
        let key = try #require(rig.ledger.deltas.keys.first)
        #expect(key.hasPrefix("\(Rig.deviceID).") && rig.ledger.deltas[key]?.contains { $0.type == .exchange } == true)
        #expect(try rig.manifestPending() == 0)
    }

    // MARK: Bodies are decided by the base

    @Test("A Doc the new world has not touched takes the old body, uploaded as the old package itself")
    func docBodyApplied() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try rig.doc("doc-a", title: "A", body: Rig.docBody)
        try await rig.seed()
        try await Self.later()
        try rig.doc("doc-a", title: "A", body: Rig.docBody.replacingOccurrences(of: "Intro paragraph.", with: "Intro paragraph, edited on the web."))

        try await rig.imported()
        let patch = try #require(try rig.patch(.artifact, "doc-a"))
        #expect(patch.changes["body"] != nil, "applied, whatever its stamp")
        #expect(rig.uploader.owners() == ["doc-a"])
        #expect(try rig.store.scalarInteger("SELECT COUNT(*) FROM ck_patches WHERE wire_id LIKE 'recovered:%'") == 0, "no Recovered Doc")
    }

    @Test("A Doc both worlds changed keeps the new world's body and gets exactly one Recovered Doc, whichever Macs run the pass")
    func docBodyRecovered() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try rig.doc("doc-a", title: "A", body: Rig.docBody)
        try await rig.seed()
        let newBody = FileRef(owner: "doc-a", role: "body", hash: "feedbeef", size: 3, mime: ArtifactBody.packageMime, encoding: "identity", storedParts: [Data("new".utf8)])
        try rig.newWorldEdit(.artifact, "doc-a", ["body": newBody.value], ms: SyncTime.milliseconds(Date().addingTimeInterval(3_600)))
        try await Self.later()
        try rig.doc("doc-a", title: "A", body: Rig.docBody.replacingOccurrences(of: "Intro paragraph.", with: "Intro paragraph, edited on the web."))

        try await rig.imported(.other)
        try await rig.imported(.importer)
        #expect(try rig.patch(.artifact, "doc-a")?.changes["body"] == nil, "the new world's body stays")
        #expect(try rig.store.scalarInteger("SELECT COUNT(*) FROM ck_patches WHERE record_type = 'Artifact' AND wire_id LIKE 'recovered:doc-a:%'") == 1, "one record between both passes")
        let title = try rig.store.scalarText("SELECT patch_json FROM ck_patches WHERE wire_id LIKE 'recovered:doc-a:%'")
        #expect(title?.contains("Recovered: A") == true)
    }

    @Test("Notes the old world edited are applied when untouched, and become one Recovered Doc when the new world edited them too")
    func notes() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let notebook = try rig.notebook("Notes")
        try rig.setNotes(notebook, "First thoughts")
        try await rig.seed()
        let notesID = NotesDoc.id(notebookID: notebook)
        try await Self.later()
        try rig.setNotes(notebook, "First thoughts, then more")

        try await rig.imported()
        #expect(try rig.patch(.artifact, notesID)?.changes["body"] != nil, "untouched notes take the old-world notes")
        #expect(rig.uploader.uploads.last?.mime == "text/markdown")
        try await rig.sendPatches()

        let other = try Rig()
        defer { other.cleanUp() }
        let second = try other.notebook("Notes")
        try other.setNotes(second, "First thoughts")
        try await other.seed()
        let edited = FileRef(owner: notesID, role: "body", hash: "feedbeef", size: 3, mime: "text/markdown", encoding: "gzip", storedParts: [Data("new".utf8)])
        try other.newWorldEdit(.artifact, NotesDoc.id(notebookID: second), ["body": edited.value], ms: SyncTime.milliseconds(Date().addingTimeInterval(3_600)))
        try await Self.later()
        try other.setNotes(second, "First thoughts, then more")
        try await other.imported()
        #expect(try other.store.scalarInteger("SELECT COUNT(*) FROM ck_patches WHERE wire_id LIKE 'recovered:notes:\(second):%'") == 1)
    }

    // MARK: payloadAsset is payload (R5-2), and a Team's zone

    @Test("A chat over 512 KiB that gained a turn is imported with its new content: its payloadAsset is read as payload")
    func longChat() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let notebook = try rig.notebook("Long chats")
        try ChatSyncFixture.addChat(rig.sender, "chat-long", kind: .chat, goalID: notebook)
        try ChatSyncFixture.addExchange(rig.sender, chat: "chat-long", question: String(repeating: "Why does the proton gradient matter? ", count: 16_000))
        try rig.publish(.reviewSession, "chat-long")
        let stored = try rig.oldRecord(.reviewSession, "chat-long")
        #expect(stored.hasEmptyPayload, "the chat is long enough to travel whole in payloadAsset")
        try await rig.seed()
        try await Self.later()
        try rig.addTurn(to: "chat-long", question: "And what comes after?")

        let report = try await rig.imported()
        #expect(report.changed == 1 && report.failed.isEmpty && report.creates == 1, "\(report)")
        let patch = try #require(try rig.store.scalarText("SELECT patch_json FROM ck_patches WHERE record_type = 'Exchange'"))
        #expect(patch.contains("And what comes after?"), "the new turn is created whole from the long chat")
    }

    @Test("A write in an old Team zone reaches the space this Mac holds, and waits while the space is not on this Mac")
    func teamZone() async throws {
        for holdsSpace in [true, false] {
            let rig = try Rig()
            defer { rig.cleanUp() }
            try rig.source("src-t")
            try await rig.seed()
            if holdsSpace {
                try ChatSyncFixture.holdSpaceNotebook(rig.store, "team-nb")
                try rig.finishFetchOfEveryZone()
            }
            // The team's Source is written into the team's own old zone, which the base does not name yet.
            var record = try rig.oldRecord(.source, "src-t")
            let teamZone = "Team-s1"
            record.id = CloudRecordID(record.id.recordName, in: CloudZoneID(teamZone))
            rig.server.put([record], zone: teamZone, owner: Rig.learner, container: FakeCloudKit.legacyContainer)
            var mark = try #require(rig.base.current)
            mark.zones.append(teamZone)
            rig.base.setWatermark(mark)

            let report = try await rig.imported()
            let waiting = try await rig.local.perform { try MigrationImportState.waitingRecords($0.connection) }
            if holdsSpace {
                #expect(report.creates >= 1 && waiting.isEmpty, "\(report)")
                #expect(try rig.store.scalarInteger("SELECT COUNT(*) FROM ck_patches WHERE record_type = 'Source' AND zone_key = 'private/Space-s1'") == 1, "created in the space")
            } else {
                #expect(report.creates == 0 && report.waiting == 1 && waiting.contains { $0.hasPrefix("\(teamZone)/") }, "\(report)")
            }
        }
    }

    @Test("A joined space is written only on a roster that says read-write: otherwise the old record waits and no patch is queued that SpaceSync would refuse for ever (F3)")
    func joinedSpaceNeedsReadWrite() async throws {
        for permission in ["readWrite", "readOnly"] {
            let rig = try Rig()
            defer { rig.cleanUp() }
            try rig.source("src-t")
            try await rig.seed()
            try ChatSyncFixture.holdSpaceNotebook(rig.store, "team-nb")
            try rig.store.execute("UPDATE ck_zones SET database = 'shared', permission = ? WHERE zone_name = 'Space-s1'", [.text(permission)])
            try rig.finishFetchOfEveryZone()
            var record = try rig.oldRecord(.source, "src-t")
            record.id = CloudRecordID(record.id.recordName, in: CloudZoneID("Team-s1"))
            rig.server.put([record], zone: "Team-s1", owner: Rig.learner, container: FakeCloudKit.legacyContainer)
            var mark = try #require(rig.base.current)
            mark.zones.append("Team-s1")
            rig.base.setWatermark(mark)

            let report = try await rig.imported()
            if permission == "readWrite" {
                #expect(report.creates >= 1, "\(report)")
            } else {
                #expect(report.creates == 0 && report.waiting == 1, "\(report)")
                #expect(try rig.store.scalarInteger("SELECT COUNT(*) FROM ck_patches WHERE zone_key LIKE '%Space-s1'") == 0, "nothing is queued for a space that refuses it")
            }
        }
    }
}

extension MigrationImportRig {
    /// The name of the old record of a notebook (its `LearningGoal` record): a digest of its entity and id.
    func goalRecordName(_ notebookID: String) throws -> String {
        let name = CloudKitRecordMapper.recordName(for: .learningGoal, logicalKey: notebookID)
        return try #require(server.recordNames(zone: Self.zoneName, owner: Self.learner, container: FakeCloudKit.legacyContainer).first { $0 == name })
    }
}
