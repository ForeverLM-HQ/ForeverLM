import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// The migration catch-up (docs/cloudkit-schema-design.md §13.4 step 0, §13.6, WP16a): a Mac with
/// generation-1 history walks the old `Knowledge` zone and brings its tables to the old world's latest
/// state before anything is derived. The old world is another Mac's generation-1 store, whose records are
/// what `CloudKitRecordMapper.makeRecord` builds, in a `FakeCloudKit` old container (`MigrationCatchUpRig`).
@Suite("Migration catch-up")
struct MigrationCatchUpTests {
    private typealias Rig = MigrationCatchUpRig

    private static let base = Rig.baseBody
    private static let intro = "Intro paragraph."
    private static let evidence = "Line about the evidence."

    private static func introEdited(_ word: String) -> String { base.replacingOccurrences(of: intro, with: "Intro paragraph, \(word).") }
    private static func evidenceEdited(_ word: String) -> String { base.replacingOccurrences(of: evidence, with: "Line about the evidence, \(word).") }

    // MARK: Per record

    @Test("A changed old record is applied, an unchanged one is left alone, and the tag becomes what this Mac last synced")
    func changedRecordIsApplied() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try rig.lastSynced(try rig.senderDoc("doc-a", title: "A", body: Self.base))
        try rig.lastSynced(try rig.senderDoc("doc-b", title: "B", body: Self.base))
        let renamed = try rig.senderDoc("doc-a", title: "A renamed", body: Self.base)

        let report = try await rig.applied()
        #expect(try rig.title("doc-a") == "A renamed")
        #expect(try rig.title("doc-b") == "B")
        #expect(report.applied == 1 && report.unchanged == 1 && report.failed.isEmpty, "\(report)")
        let metadata = try #require(try rig.receiver.loadSyncMetadata(entity: .artifact, logicalKey: "doc-a"))
        #expect(metadata.systemFieldsData.flatMap(Rig.tagReader) == renamed.changeTag)
        #expect(try !rig.receiver.hasPendingSyncChange(entity: .artifact, logicalKey: "doc-a"))
    }

    @Test("A pending change later than the server's userModificationDate keeps the local values; an earlier one takes the server's (R3-m1)",
          arguments: [3600.0, -3600.0])
    func pendingRule(offset: Double) async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try rig.lastSynced(try rig.senderDoc("doc-r", title: "R", body: Self.base))
        let old = try rig.senderDoc("doc-r", title: "R from the old world", body: Self.base)
        try rig.receiver.saveArtifactRecord(Rig.artifact("doc-r", title: "R here"))
        try rig.pending(.artifact, "doc-r", at: old.oldModifiedAt.addingTimeInterval(offset))

        let report = try await rig.applied()
        if offset > 0 {
            #expect(try rig.title("doc-r") == "R here")
            #expect(report.keptLocal == 1 && report.applied == 0)
            #expect(try rig.receiver.hasPendingSyncChange(entity: .artifact, logicalKey: "doc-r"), "the change is still pending for the seed")
        } else {
            #expect(try rig.title("doc-r") == "R from the old world")
            #expect(report.applied == 1 && report.keptLocal == 0)
            #expect(try !rig.receiver.hasPendingSyncChange(entity: .artifact, logicalKey: "doc-r"))
        }
    }

    // MARK: Doc bodies (R7-m7, R8-1, R8-m9)

    @Test("A Doc edited on this Mac and in the old world over the same passage keeps this Mac's body and yields one Recovered Doc, whichever edit is later",
          arguments: [3600.0, -3600.0])
    func overlappingEditsRecover(offset: Double) async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try rig.lastSynced(try rig.senderDoc("doc-o", title: "O", body: Self.base))
        let mine = Self.introEdited("mine"), theirs = Self.introEdited("theirs")
        let old = try rig.senderDoc("doc-o", title: "O", body: theirs)
        try rig.receiver.saveArtifactMarkdownAfterMerge(mine, artifactID: "doc-o")
        try rig.pending(.artifact, "doc-o", at: old.oldModifiedAt.addingTimeInterval(offset))
        let before = try rig.receiver.loadSyncMetadata(entity: .artifact, logicalKey: "doc-o")

        let report = try await rig.applied()
        #expect(try rig.receiverBody("doc-o") == mine)
        let recovered = try rig.recoveredDocs()
        #expect(recovered.count == 1 && report.recoveredDocs == recovered, "\(recovered)")
        #expect(try rig.receiverBody(try #require(recovered.first)) == theirs, "the old world's body is not dropped")
        #expect(try rig.title(try #require(recovered.first)) == "Recovered: O")

        // A second walk meets the same difference, a record the server holds again as it was before this walk
        // took it (its old tag, its pending change), and makes no second Doc.
        try rig.receiver.saveSyncMetadata(try #require(before))
        try rig.pending(.artifact, "doc-o", at: old.oldModifiedAt.addingTimeInterval(offset))
        _ = try await rig.applied()
        #expect(try rig.recoveredDocs() == recovered)
    }

    @Test("A Recovered Doc owed by a batch that applied survives a run cancelled right after it, and the next run makes it (F1)")
    func recoverySurvivesACancelledRun() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try rig.lastSynced(try rig.senderDoc("doc-q1", title: "Q1", body: Self.base))
        try rig.lastSynced(try rig.senderDoc("doc-q2", title: "Q2", body: Self.base))
        let mine = Self.introEdited("mine"), theirs = Self.introEdited("theirs")
        let old = try rig.senderDoc("doc-q1", title: "Q1", body: theirs)
        try rig.receiver.saveArtifactMarkdownAfterMerge(mine, artifactID: "doc-q1")
        // The pending change is older than the old record's date, so the old record is applied (its tag stored and
        // the change cleared) while this Mac's body stays: the walk that follows meets nothing to decide again.
        try rig.pending(.artifact, "doc-q1", at: old.oldModifiedAt.addingTimeInterval(-3600))

        // Steps: the asset needs, the plan, one batch per record (two), then the deletions: cancelled there.
        let cancelling = CancellingStoreAccess(store: rig.receiver, cancelAt: 5)
        await #expect(throws: CancellationError.self) { _ = try await rig.catchUp(through: cancelling, batchSize: 1) }
        #expect(try rig.recoveredDocs().isEmpty, "the Doc is made after every record is in")
        #expect(try rig.owedRecoveries() == 1, "but it is owed durably: the old tag is already stored, so no later walk would decide it again")
        let metadata = try #require(try rig.receiver.loadSyncMetadata(entity: .artifact, logicalKey: "doc-q1"))
        #expect(metadata.systemFieldsData.flatMap(Rig.tagReader) == old.changeTag)

        let report = try await rig.applied()
        #expect(report.unchanged == 2, "the second run finds both records as they are: \(report)")
        let recovered = try rig.recoveredDocs()
        #expect(recovered.count == 1 && report.recoveredDocs == recovered, "\(recovered)")
        #expect(try rig.receiverBody(try #require(recovered.first)) == theirs, "the old world's body is not lost")
        #expect(try rig.receiverBody("doc-q1") == mine)
        #expect(try rig.owedRecoveries() == 0)
    }

    @Test("A notebook's notes owed as a Recovered Doc survive a run cancelled after the notebook applied (F1)")
    func notesRecoverySurvivesACancelledRun() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let notebook = try rig.sharedNotebook(notes: "v1")
        try rig.setSenderNotes(notebook, "v2 from the old world")
        let old = try rig.publish(.learningGoal, notebook)
        try rig.setReceiverNotes(notebook, "mine")
        try rig.pending(.learningGoal, notebook, at: old.oldModifiedAt.addingTimeInterval(-3600))

        // The asset needs, the plan, the one batch, then the deletions: cancelled there.
        let cancelling = CancellingStoreAccess(store: rig.receiver, cancelAt: 4)
        await #expect(throws: CancellationError.self) { _ = try await rig.catchUp(through: cancelling, batchSize: 1) }
        #expect(try rig.receiverNotes(notebook) == "mine")
        #expect(try rig.owedRecoveries() == 1)

        _ = try await rig.applied()
        let expectedID = RecoveredDoc.id(artifactID: NotesDoc.id(notebookID: notebook), hash: SyncIdentity.sha256Hex(Data("v2 from the old world".utf8)))
        #expect(try rig.recoveredDocs() == [expectedID])
        #expect(try rig.receiverBody(expectedID) == "v2 from the old world")
    }

    @Test("A record that does not apply keeps no snapshot row, so the shared base never calls its old change handled (F9)")
    func failedRecordHasNoSnapshotRow() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try rig.lastSynced(try rig.senderDoc("doc-ok", title: "OK", body: Self.base))
        var broken = try rig.senderDoc("doc-bad", title: "Bad", body: Self.base)
        // The old record's title is blank, which today's writer refuses.
        let payload = try #require(broken.payload)
        var object = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        var artifact = try #require(object["artifact"] as? [String: Any])
        artifact["title"] = " "
        object["artifact"] = artifact
        broken.payload = try JSONSerialization.data(withJSONObject: object)
        rig.server.put([broken], zone: CloudKitZoneHome.knowledgeZoneName, owner: Rig.learner, container: FakeCloudKit.legacyContainer)

        let report = try await rig.applied()
        #expect(report.failed == ["artifact:doc-bad"], "\(report)")
        #expect(try rig.receiver.scalarInteger("SELECT COUNT(*) FROM ck_legacy_snapshot WHERE record_name = ?", [.text(broken.id.recordName)]) == 0)
        #expect(try rig.receiver.scalarInteger("SELECT COUNT(*) FROM ck_legacy_snapshot") == 1, "the record that applied has its row")
    }

    @Test("An old record whose payload carries another key than the one its name was minted from applies, and its sync_metadata row moves to that key")
    func recordNameHeldUnderAnotherKeyApplies() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        // Generation 1 named a dismissed source's record after the absolute path it was dismissed under; a later
        // build rewrote the URL to the library-relative path and saved the same record with that payload.
        let absolute = "/Users/learner/Library/Mobile Documents/com~apple~CloudDocs/Documents/Papers/dismissed.pdf"
        let relative = "Papers/dismissed.pdf"
        let name = CloudKitRecordMapper.recordName(for: .dismissedSource, logicalKey: absolute)
        try rig.sender.saveDismissedSourceRecord(CloudKitDismissedSourcePayload(url: relative, title: "A dismissed paper", dismissedAt: Date(timeIntervalSinceReferenceDate: 500)))
        let change = try #require(try rig.sender.pendingSyncChanges().first { $0.entity == .dismissedSource && $0.logicalKey == relative })
        let made = try #require(try CloudKitRecordMapper.makeRecord(for: change, store: rig.sender))
        let renamed = CKRecord(recordType: made.recordType, recordID: CloudKitRecordMapper.recordID(for: .dismissedSource, logicalKey: absolute))
        for key in made.allKeys() { renamed[key] = made[key] }
        for key in made.encryptedValues.allKeys() { renamed.encryptedValues[key] = made.encryptedValues[key] }
        rig.server.put([CloudKitMapping.record(renamed)], zone: CloudKitZoneHome.knowledgeZoneName, owner: Rig.learner, container: FakeCloudKit.legacyContainer)
        // This Mac last synced the record under its absolute path.
        try rig.receiver.saveSyncMetadata(CloudKitSyncMetadata(
            entity: .dismissedSource, logicalKey: absolute, recordName: name, systemFieldsData: Data("an older tag".utf8),
            userModificationDate: Date(timeIntervalSinceReferenceDate: 100), isDeleted: false
        ))

        let report = try await rig.applied()
        #expect(report.failed.isEmpty && report.applied == 1, "\(report)")
        let held = try #require(try rig.receiver.loadSyncMetadata(recordName: name))
        #expect(held.entity == .dismissedSource && held.logicalKey == relative && !held.isDeleted)
        #expect(try rig.receiver.loadSyncMetadata(entity: .dismissedSource, logicalKey: absolute) == nil, "one row per record name")
        #expect(try rig.receiver.scalarInteger("SELECT COUNT(*) FROM dismissed_sources WHERE url = ?", [.text(relative)]) == 1)
        #expect(try rig.receiver.scalarInteger("SELECT COUNT(*) FROM ck_legacy_snapshot WHERE record_name = ?", [.text(name)]) == 1, "and it has its snapshot row")
    }

    @Test("A podcast whose transcript cleanup arrives without the transcript applies, since the walk fetches no file asset, and this Mac keeps its own transcript and cleanup")
    func podcastCleanupWithoutItsTranscriptApplies() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let editorial = String(repeating: "Replay during slow-wave sleep is what moves a memory from fragile to durable. ", count: 6)
        let input = "Welcome back. " + editorial + "This episode is brought to you by Sponsor. Use code SHOW for a discount. " + editorial
        let clean = "Welcome back. " + editorial + editorial
        var episode = StudioArticle(url: "apple-podcast://episode/catch-up-episode", title: "An episode", sourceType: .podcast, id: "catch-up-episode")
        episode.domain = "A Show"
        try rig.sender.saveSource(episode)
        try rig.sender.saveTranscript(episode.id, input)
        let candidate = try #require(try rig.sender.podcastTranscriptCleanupCandidates(limit: 1).first)
        let metadata = PodcastTranscriptCleanupMetadata(
            cleanerVersion: PodcastTranscriptCleanupMetadata.currentVersion, inputSHA256: candidate.inputSHA256,
            cleanSHA256: PaperContentPreparationService.sha256(clean), preparedAt: Date()
        )
        try rig.sender.applyPodcastTranscriptCleanup(candidate: candidate, prepared: PreparedPodcastTranscriptCleanup(input: input, clean: clean, metadata: metadata))
        var renamed = episode
        renamed.title = "An episode, renamed in the old world"
        try rig.sender.saveSource(renamed)
        let record = try rig.publish(.source, episode.id)
        let payload = try JSONDecoder().decode(CloudKitSourcePayload.self, from: try #require(record.payload))
        #expect(payload.podcastTranscriptCleanup != nil, "the old record names its cleanup")

        // This Mac holds the episode with its own cleaned transcript, and no change of it is unsent.
        let mine = "Welcome back. " + editorial + "This Mac's own copy. " + editorial
        try rig.receiver.saveSource(episode)
        try rig.receiver.saveTranscript(episode.id, mine)
        try rig.receiver.clearAllPendingSyncChanges()

        let report = try await rig.applied()
        #expect(report.failed.isEmpty && report.applied == 1, "\(report)")
        #expect(try rig.receiver.scalarText("SELECT title FROM podcasts WHERE source_id = ?", [.text(episode.id)]) == renamed.title)
        #expect(try rig.receiver.loadSourceContent(episode.id) == mine, "the transcript this Mac holds stays until the file assets arrive")
        #expect(try rig.receiver.scalarInteger("SELECT COUNT(*) FROM ck_legacy_snapshot WHERE record_name = ?", [.text(record.id.recordName)]) == 1)
    }

    @Test("The 5% guard trips above five percent of what sync_metadata names, never at it, and never over nothing (T7)")
    func guardBoundary() {
        #expect(!MigrationCatchUpRules.tripsGuard(deleting: 5, of: 100), "exactly five percent goes ahead")
        #expect(MigrationCatchUpRules.tripsGuard(deleting: 6, of: 100))
        #expect(!MigrationCatchUpRules.tripsGuard(deleting: 1, of: 20))
        #expect(MigrationCatchUpRules.tripsGuard(deleting: 2, of: 20))
        #expect(MigrationCatchUpRules.tripsGuard(deleting: 1, of: 1), "a library of one that loses its one record asks")
        #expect(!MigrationCatchUpRules.tripsGuard(deleting: 0, of: 100))
        #expect(!MigrationCatchUpRules.tripsGuard(deleting: 3, of: 0), "no history, no guard")
    }

    @Test("The default change-tag reader reads the system fields CloudKit's own archiver writes, and nothing else (T5)")
    func defaultTagReaderReadsRealSystemFields() throws {
        let zone = CKRecordZone.ID(zoneName: "Knowledge", ownerName: CKCurrentUserDefaultName)
        let record = CKRecord(recordType: "Artifact", recordID: CKRecord.ID(recordName: "r1", zoneID: zone))
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        let blob = archiver.encodedData

        let decoded = try #require(CloudKitRecordMapper.decodeSystemFields(blob), "the blob is a real archive of a record's system fields")
        #expect(decoded.recordID.recordName == "r1")
        let reader = MigrationCatchUpConfiguration().changeTag
        #expect(reader(blob) == decoded.recordChangeTag, "the default reader is the mapper's, not the rig's")
        #expect(reader(Data("not an archive".utf8)) == nil, "bytes that are no archive have no tag")
    }

    @Test("A Doc renamed here but not edited takes the old world's body with no Recovered Doc (R8-1)")
    func renamedDocTakesOldBody() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try rig.lastSynced(try rig.senderDoc("doc-n", title: "N", body: Self.base))
        let theirs = Self.introEdited("edited on the web")
        let old = try rig.senderDoc("doc-n", title: "N", body: theirs)
        try rig.receiver.saveArtifactRecord(Rig.artifact("doc-n", title: "N renamed here"))
        try rig.pending(.artifact, "doc-n", at: old.oldModifiedAt.addingTimeInterval(3600))
        #expect(try !MigrationBodies.docOwnEdit("doc-n", store: rig.receiver), "a rename is no edit of the body")

        _ = try await rig.applied()
        #expect(try rig.receiverBody("doc-n") == theirs)
        #expect(try rig.title("doc-n") == "N renamed here", "the per-record rule still keeps the rename")
        #expect(try rig.recoveredDocs().isEmpty)
    }

    @Test("A Doc edited on both sides whose edits merge cleanly takes the merged body, with no Recovered Doc, and it is still this Mac's edit (R8-m9)")
    func cleanMerge() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try rig.lastSynced(try rig.senderDoc("doc-m", title: "M", body: Self.base))
        let theirs = Self.evidenceEdited("cited")
        let old = try rig.senderDoc("doc-m", title: "M", body: theirs)
        try rig.receiver.saveArtifactMarkdownAfterMerge(Self.introEdited("sharpened"), artifactID: "doc-m")
        try rig.pending(.artifact, "doc-m", at: old.oldModifiedAt.addingTimeInterval(-3600))

        _ = try await rig.applied()
        let merged = try #require(try rig.receiverBody("doc-m"))
        #expect(merged.contains("Intro paragraph, sharpened.") && merged.contains("Line about the evidence, cited."))
        #expect(try rig.recoveredDocs().isEmpty)
        #expect(try rig.receiver.loadArtifactBaseMarkdown("doc-m") == theirs, "the old world's body is the base now")
        #expect(try MigrationBodies.docOwnEdit("doc-m", store: rig.receiver), "the merged body is still unsent")
    }

    // MARK: Notebook notes (R7-m7, R8-1)

    @Test("An unchanged old notebook record leaves notes this Mac edited, and the walk's notes are the notes base")
    func notesEditedHereWithUnchangedRecord() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let notebook = try rig.sharedNotebook(notes: "synced notes")
        try rig.setReceiverNotes(notebook, "edited here")
        try rig.pending(.learningGoal, notebook, at: Date())

        let report = try await rig.applied()
        #expect(report.unchanged == 1)
        #expect(try rig.receiverNotes(notebook) == "edited here")
        #expect(try rig.notesBase(notebook) == "synced notes")
        #expect(try rig.recoveredDocs().isEmpty)
    }

    @Test("A notebook whose old record changed with no row pending takes the old world's notes")
    func notesTakeOldWorld() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let notebook = try rig.sharedNotebook(notes: "v1")
        try rig.setSenderNotes(notebook, "v2 from the old world")
        try rig.publish(.learningGoal, notebook)

        _ = try await rig.applied()
        #expect(try rig.receiverNotes(notebook) == "v2 from the old world")
        #expect(try rig.notesBase(notebook) == "v2 from the old world")
        #expect(try rig.recoveredDocs().isEmpty)
    }

    @Test("A notebook whose old record changed while a change was pending keeps the local notes beside one Recovered Doc, and the walk's notes stay the base",
          arguments: [3600.0, -3600.0])
    func notesEditedOnBothSides(offset: Double) async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let notebook = try rig.sharedNotebook(notes: "v1")
        try rig.setSenderNotes(notebook, "v2 from the old world")
        let old = try rig.publish(.learningGoal, notebook)
        try rig.setReceiverNotes(notebook, "mine")
        try rig.pending(.learningGoal, notebook, at: old.oldModifiedAt.addingTimeInterval(offset))

        _ = try await rig.applied()
        #expect(try rig.receiverNotes(notebook) == "mine")
        #expect(try rig.notesBase(notebook) == "v2 from the old world")
        let recovered = try rig.recoveredDocs()
        #expect(recovered.count == 1)
        let expectedID = RecoveredDoc.id(artifactID: NotesDoc.id(notebookID: notebook), hash: SyncIdentity.sha256Hex(Data("v2 from the old world".utf8)))
        #expect(recovered == [expectedID])
        #expect(try rig.receiverBody(expectedID) == "v2 from the old world")
    }

    // MARK: Deletions and the guard

    @Test("An old-world deletion is applied; one with a local change pending is kept and logged")
    func deletions() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        var records: [String: CloudRecord] = [:]
        for index in 0..<40 {
            let id = "doc-\(index)"
            let record = try rig.senderDoc(id, title: id, body: Self.base)
            try rig.lastSynced(record)
            records[id] = record
        }
        try await rig.deleteFromOldWorld(try #require(records["doc-1"]).id.recordName)
        let report = try await rig.applied()
        #expect(report.deletedLocally == 1)
        #expect(try rig.receiver.scalarInteger("SELECT COUNT(*) FROM global_artifacts WHERE id = 'doc-1'") == 0)

        let keptName = try #require(records["doc-2"]).id.recordName
        try await rig.deleteFromOldWorld(keptName)
        try rig.pending(.artifact, "doc-2", at: Date())
        let kept = try await rig.applied()
        #expect(kept.deletedLocally == 0)
        #expect(kept.keptPendingDeletions == [keptName])
        #expect(try rig.receiver.scalarInteger("SELECT COUNT(*) FROM global_artifacts WHERE id = 'doc-2'") == 1)
    }

    @Test("A walk that would delete more than 5% of the rows sync_metadata names applies nothing and asks; Apply runs it with the guard lifted")
    func guardStopsAndAsks() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        var names: [String] = []
        for index in 0..<4 {
            let record = try rig.senderDoc("doc-\(index)", title: "doc-\(index)", body: Self.base)
            try rig.lastSynced(record)
            names.append(record.id.recordName)
        }
        _ = try rig.senderDoc("doc-0", title: "doc-0 changed", body: Self.base)
        try await rig.deleteFromOldWorld(names[2])
        try await rig.deleteFromOldWorld(names[3])

        guard case .guardTripped(let question) = try await rig.catchUp() else {
            Issue.record("the guard did not trip")
            return
        }
        #expect(question.deleting == 2 && question.of == 4 && question.account == Rig.learner)
        #expect(try rig.title("doc-0") == "doc-0", "nothing was applied")
        #expect(try rig.receiver.scalarInteger("SELECT COUNT(*) FROM global_artifacts WHERE id IN ('doc-2', 'doc-3')") == 2, "nothing was deleted")

        let report = try await rig.applied(guardLifted: true)
        #expect(report.deletedLocally == 2)
        #expect(try rig.title("doc-0") == "doc-0 changed")
    }

    @Test("A missing Knowledge zone is no old world: nothing is applied or deleted")
    func missingKnowledgeZone() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try rig.lastSynced(try rig.senderDoc("doc-k", title: "K", body: Self.base))
        rig.server.deleteZone(CloudKitZoneHome.knowledgeZoneName, owner: Rig.learner, container: FakeCloudKit.legacyContainer, reason: .purged)
        #expect(try await rig.catchUp() == .noOldWorld(account: Rig.learner))
        #expect(try rig.title("doc-k") == "K")
        #expect(try rig.receiver.scalarInteger("SELECT COUNT(*) FROM ck_legacy_snapshot") == 0)
    }

    // MARK: payloadAsset is payload (R5-2)

    @Test("A changed Doc's package is fetched and applied before the derivations, and an unchanged Doc's package is never downloaded")
    func onlyChangedPackagesAreFetched() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let changed = try rig.senderDoc("doc-c1", title: "C1", body: Self.base)
        let unchanged = try rig.senderDoc("doc-c2", title: "C2", body: Self.base)
        try rig.lastSynced(changed)
        try rig.lastSynced(unchanged)
        let theirs = Self.introEdited("from the web")
        let updated = try rig.senderDoc("doc-c1", title: "C1", body: theirs)
        rig.server.resetCalls()

        _ = try await rig.applied()
        #expect(try rig.receiverBody("doc-c1") == theirs)
        let fetchedByName = rig.server.calls.filter { $0.operation == .records }.flatMap(\.recordNames)
        #expect(fetchedByName == [updated.id.recordName], "only the changed Doc was fetched by name: \(fetchedByName)")
    }

    @Test("The walk stages the package of a Doc this Mac cannot reproduce, and of no Doc whose own encoding reproduces its bodyRevision (R8-m6)")
    func stagesPackagesTheSeedNeeds() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let edited = try rig.senderDoc("doc-s1", title: "S1", body: Self.base)
        let same = try rig.senderDoc("doc-s2", title: "S2", body: Self.base)
        try rig.lastSynced(edited)
        try rig.lastSynced(same)
        // This Mac's encoding of the first no longer reproduces the old revision.
        try rig.receiver.saveArtifactMarkdownAfterMerge(Self.introEdited("mine"), artifactID: "doc-s1")

        let report = try await rig.applied()
        let revision = try #require(try rig.receiver.loadArtifactBodyPackageForSync("doc-s2")?.revision)
        #expect(OldContainerStagedPackages.staged(artifactID: "doc-s2", revision: revision, store: rig.receiver) == nil)
        let package = try #require(try rig.storedPackageRevision(edited))
        #expect(OldContainerStagedPackages.staged(artifactID: "doc-s1", revision: package, store: rig.receiver) != nil)
        #expect(report.stagedPackages == 1)
    }

    // MARK: File assets, the snapshot, the notes base

    @Test("Source file assets are queued for after the activation, not fetched inside the walk")
    func sourceAssetsAreQueued() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        var article = StudioArticle(url: "https://example.org/catch-up/1", title: "A paper", sourceType: .article)
        try rig.sender.insertSourceIfNew(&article)
        try rig.sender.markRecordChanged(entity: .source, logicalKey: article.id)
        let record = try rig.publish(.source, article.id)
        rig.server.resetCalls()

        let report = try await rig.applied()
        #expect(report.queuedAssets == 1)
        #expect(try rig.receiver.scalarInteger("SELECT COUNT(*) FROM sources WHERE id = ?", [.text(article.id)]) == 1)
        let queued = try rig.receiver.scalarText("SELECT payload_json FROM ck_backfill_queue WHERE kind = ? AND target = ?", [.text(MigrationCatchUpApplier.assetQueueKind), .text("Knowledge/\(record.id.recordName)")])
        #expect(queued?.contains(CKRecord.FieldKey.sourcePDFAsset) == true)
        #expect(rig.server.calls.filter { $0.operation == .records }.isEmpty, "no asset was fetched by name")
    }

    @Test("The snapshot, the tokens, the walk's start and the account are stored, and every returned notebook has its notes base")
    func snapshotIsStored() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let notebook = try rig.sharedNotebook(notes: "the notes")
        let doc = try rig.senderDoc("doc-snap", title: "Snap", body: Self.base)

        let report = try await rig.applied()
        #expect(report.snapshotRows == 2 && report.notesBases == 1)
        let tag = try rig.receiver.scalarText("SELECT change_tag FROM ck_legacy_snapshot WHERE old_zone = 'Knowledge' AND record_name = ?", [.text(doc.id.recordName)])
        #expect(tag == doc.changeTag)
        let notebookRecord = try #require(try rig.receiver.scalarText("SELECT record_name FROM sync_metadata WHERE entity_type = 'learningGoal' AND logical_key = ?", [.text(notebook)]))
        let hashes = try #require(try rig.receiver.scalarText("SELECT field_hashes FROM ck_legacy_snapshot WHERE old_zone = 'Knowledge' AND record_name = ?", [.text(notebookRecord)]))
        #expect(hashes.contains("Notebook:\(notebook)"), "the owner flag and field hashes come from LegacyV2Mapping: \(hashes)")
        #expect(try MigrationCatchUpSnapshot.token(zoneKey: "migration.token.private.Knowledge", store: rig.receiver) != nil)
        #expect(try rig.notesBase(notebook) == "the notes")
        let journal = try #require(try rig.receiver.activationJournal())
        #expect(journal.catchUpAt != nil && journal.account == Rig.learner)
    }
}

extension MigrationCatchUpRig {
    /// The `bodyRevision` an old Doc record carries.
    func storedPackageRevision(_ record: CloudRecord) throws -> String? {
        guard let data = record.payload else { return nil }
        return try JSONDecoder().decode(CloudKitArtifactPayload.self, from: data).bodyRevision
    }
}
