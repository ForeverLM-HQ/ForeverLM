import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// A Doc body arriving from CloudKit while this Mac holds a newer body of its
/// own: merged against the base this device last knew the server to hold, or
/// held beside the doc when both sides changed the same passage
/// (docs/teams-design.md, decision 12).
@Suite("Artifact server merge")
struct ArtifactServerMergeTests {
    private struct Stores {
        let sender: KnowledgeStore
        let receiver: KnowledgeStore
        let roots: [URL]

        func cleanUp() {
            for root in roots { try? FileManager.default.removeItem(at: root) }
        }
    }

    private static func makeStores() throws -> Stores {
        let senderRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtifactMergeSender_\(UUID().uuidString)", isDirectory: true)
        let receiverRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtifactMergeReceiver_\(UUID().uuidString)", isDirectory: true)
        let sender = try KnowledgeStore(
            storeDirectory: senderRoot.appendingPathComponent(".appdata", isDirectory: true),
            contentDirectory: senderRoot.appendingPathComponent("Content", isDirectory: true)
        )
        let receiver = try KnowledgeStore(
            storeDirectory: receiverRoot.appendingPathComponent(".appdata", isDirectory: true),
            contentDirectory: receiverRoot.appendingPathComponent("Content", isDirectory: true)
        )
        return Stores(sender: sender, receiver: receiver, roots: [senderRoot, receiverRoot])
    }

    private static let base = "# Landscape\n\nIntro paragraph.\n\n## Evidence\n\nLine about the evidence.\n"

    private static func artifact(_ id: String = "doc-merge") -> ArtifactRecord {
        ArtifactRecord(
            id: id,
            title: "Landscape",
            homeNotebookID: nil,
            linkedNotebookIDs: [],
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 200)
        )
    }

    /// The server record another member's Mac would upload for `theirs`.
    private static func serverRecord(body theirs: String, in sender: KnowledgeStore) throws -> CKRecord {
        try sender.saveArtifactRecord(artifact())
        try sender.saveArtifactMarkdownFromSync(theirs, artifactID: "doc-merge")
        let change = try #require(sender.pendingSyncChanges().first { $0.entity == .artifact })
        return try #require(try CloudKitRecordMapper.makeRecord(for: change, store: sender))
    }

    /// A receiver that has the base body from a previous sync and its own
    /// newer edit on top, still queued to upload.
    private static func prepareReceiver(_ receiver: KnowledgeStore, mine: String) throws {
        try receiver.saveArtifactRecord(artifact())
        try receiver.saveArtifactMarkdownFromSync(base, artifactID: "doc-merge")
        try receiver.saveArtifactMarkdownAfterMerge(mine, artifactID: "doc-merge")
        #expect(try receiver.loadArtifactBaseMarkdown("doc-merge") == base)
        #expect(try receiver.loadArtifactMarkdownForSync("doc-merge") == mine)
    }

    @Test("Changes to different paragraphs are combined and the server body becomes the base")
    func disjointEditsMerge() throws {
        let stores = try Self.makeStores()
        defer { stores.cleanUp() }
        let mine = Self.base.replacingOccurrences(of: "Intro paragraph.", with: "Intro paragraph, sharpened.")
        let theirs = Self.base.replacingOccurrences(of: "Line about the evidence.", with: "Line about the evidence, cited.")
        try Self.prepareReceiver(stores.receiver, mine: mine)
        let record = try Self.serverRecord(body: theirs, in: stores.sender)

        let merge = try #require(try CloudKitRecordMapper.mergeArtifactServerConflict(record: record, to: stores.receiver))
        #expect(merge.outcome == .merged)
        #expect(merge.applied.entity == .artifact)
        #expect(merge.applied.logicalKey == "doc-merge")
        let expected = mine.replacingOccurrences(of: "Line about the evidence.", with: "Line about the evidence, cited.")
        #expect(try stores.receiver.loadArtifactMarkdownForSync("doc-merge") == expected)
        #expect(try stores.receiver.loadArtifactBaseMarkdown("doc-merge") == theirs)
        #expect(try stores.receiver.loadArtifactHeldRemoteMarkdown("doc-merge") == nil)
        // The merged body is this device's edit, newer than the server's, so it
        // stays queued to upload.
        #expect(try stores.receiver.pendingSyncChanges().contains { $0.entity == .artifact && $0.logicalKey == "doc-merge" })
    }

    @Test("The same passage changed on both sides keeps the local body and holds the server's")
    func conflictHoldsServerBody() throws {
        let stores = try Self.makeStores()
        defer { stores.cleanUp() }
        let mine = Self.base.replacingOccurrences(of: "Intro paragraph.", with: "Intro paragraph, mine.")
        let theirs = Self.base.replacingOccurrences(of: "Intro paragraph.", with: "Intro paragraph, theirs.")
        try Self.prepareReceiver(stores.receiver, mine: mine)
        let record = try Self.serverRecord(body: theirs, in: stores.sender)

        let merge = try #require(try CloudKitRecordMapper.mergeArtifactServerConflict(record: record, to: stores.receiver))
        #expect(merge.outcome == .heldForChoice)
        #expect(try stores.receiver.loadArtifactMarkdownForSync("doc-merge") == mine)
        #expect(try stores.receiver.loadArtifactHeldRemoteMarkdown("doc-merge") == theirs)
        #expect(try stores.receiver.loadArtifactBaseMarkdown("doc-merge") == theirs)

        try stores.receiver.discardArtifactHeldRemoteMarkdown("doc-merge")
        #expect(try stores.receiver.loadArtifactHeldRemoteMarkdown("doc-merge") == nil)
    }

    @Test("Without a base the server body is held rather than guessed at")
    func missingBaseHolds() throws {
        let stores = try Self.makeStores()
        defer { stores.cleanUp() }
        let mine = Self.base + "\nMine.\n"
        try stores.receiver.saveArtifactRecord(Self.artifact())
        try stores.receiver.saveArtifactMarkdownAfterMerge(mine, artifactID: "doc-merge")
        #expect(try stores.receiver.loadArtifactBaseMarkdown("doc-merge") == nil)
        let theirs = Self.base + "\nTheirs.\n"
        let record = try Self.serverRecord(body: theirs, in: stores.sender)

        let merge = try #require(try CloudKitRecordMapper.mergeArtifactServerConflict(record: record, to: stores.receiver))
        #expect(merge.outcome == .heldForChoice)
        #expect(try stores.receiver.loadArtifactMarkdownForSync("doc-merge") == mine)
        #expect(try stores.receiver.loadArtifactHeldRemoteMarkdown("doc-merge") == theirs)
    }

    @Test("Two copies of a mnemonic reading that wrote the same source merge question by question, never held for a choice")
    func readingBodiesUnion() throws {
        let stores = try Self.makeStores()
        defer { stores.cleanUp() }
        let pending = MnemonicReading(title: "R", sections: [
            .init(sourceID: "c1", title: "One"),
            .init(sourceID: "c2", title: "Two"),
        ])
        let ours = MnemonicQuestion.mint(sourceID: "c1", quote: "The first words.", question: "What came first?", answer: "The words.")
        let theirsQuestion = MnemonicQuestion.mint(sourceID: "c1", quote: "The other words.", question: "What came next?", answer: "Others.")
        let mine = pending.writing([ours], in: "c1").reading.markdown
        let theirs = pending.writing([theirsQuestion], in: "c1").reading.markdown
        try stores.receiver.saveArtifactRecord(Self.artifact())
        try stores.receiver.saveArtifactMarkdownFromSync(pending.markdown, artifactID: "doc-merge")
        try stores.receiver.saveArtifactMarkdownAfterMerge(mine, artifactID: "doc-merge")
        let record = try Self.serverRecord(body: theirs, in: stores.sender)

        let merge = try #require(try CloudKitRecordMapper.mergeArtifactServerConflict(record: record, to: stores.receiver))
        #expect(merge.outcome == .merged)
        let body = try #require(try stores.receiver.loadArtifactMarkdownForSync("doc-merge"))
        let merged = MnemonicReading.parse(body, fallbackTitle: "R")
        #expect(merged.section(sourceID: "c1")?.questions.map(\.id) == [ours.id, theirsQuestion.id])
        #expect(merged.pendingSourceIDs == ["c2"])
        #expect(try stores.receiver.loadArtifactHeldRemoteMarkdown("doc-merge") == nil)
        #expect(try stores.receiver.loadArtifactBaseMarkdown("doc-merge") == theirs)
    }

    @Test("A body the server already holds is identical, and nothing is held")
    func identicalBodies() throws {
        let stores = try Self.makeStores()
        defer { stores.cleanUp() }
        let same = Self.base.replacingOccurrences(of: "Intro paragraph.", with: "Intro paragraph, agreed.")
        try Self.prepareReceiver(stores.receiver, mine: same)
        let record = try Self.serverRecord(body: same, in: stores.sender)

        let merge = try #require(try CloudKitRecordMapper.mergeArtifactServerConflict(record: record, to: stores.receiver))
        #expect(merge.outcome == .identical)
        #expect(try stores.receiver.loadArtifactHeldRemoteMarkdown("doc-merge") == nil)
        #expect(try stores.receiver.loadArtifactBaseMarkdown("doc-merge") == same)
    }

    @Test("An acknowledged upload makes the body on disk the base, unless it moved on")
    func acknowledgedUploadAdoptsBase() throws {
        let stores = try Self.makeStores()
        defer { stores.cleanUp() }
        let store = stores.receiver
        try store.saveArtifactRecord(Self.artifact())
        try store.saveArtifactMarkdownAfterMerge(Self.base, artifactID: "doc-merge")
        #expect(try store.loadArtifactBaseMarkdown("doc-merge") == nil)
        let recordName = CloudKitRecordMapper.recordName(for: .artifact, logicalKey: "doc-merge")
        let package = try #require(try store.loadArtifactBodyPackageForSync("doc-merge"))
        try store.stageAssetDigests([.payloadAsset: package.revision], recordName: recordName)
        try store.commitStagedAssetDigests(recordName: recordName)

        // Edited again while the upload was in flight: the base waits.
        let edited = Self.base + "\nLater.\n"
        try store.saveArtifactMarkdownAfterMerge(edited, artifactID: "doc-merge")
        try store.adoptArtifactBaseIfCurrent("doc-merge")
        #expect(try store.loadArtifactBaseMarkdown("doc-merge") == nil)

        // The next upload carries the edited body; its acknowledgement adopts it.
        let next = try #require(try store.loadArtifactBodyPackageForSync("doc-merge"))
        try store.stageAssetDigests([.payloadAsset: next.revision], recordName: recordName)
        try store.commitStagedAssetDigests(recordName: recordName)
        try store.adoptArtifactBaseIfCurrent("doc-merge")
        #expect(try store.loadArtifactBaseMarkdown("doc-merge") == edited)
    }

    @Test("A draft of a team Doc has a deterministic hidden id")
    func draftIdentity() {
        let draft = TeamContentIdentity.draftArtifactID(teamID: "team-1", teamArtifactID: "doc_abc")
        #expect(TeamContentIdentity.isDraftArtifactID(draft))
        #expect(draft == TeamContentIdentity.draftArtifactID(teamID: "team-1", teamArtifactID: "doc_abc"))
        #expect(draft != TeamContentIdentity.draftArtifactID(teamID: "team-2", teamArtifactID: "doc_abc"))
        #expect(!TeamContentIdentity.isDraftArtifactID("doc_abc"))
    }

    /// A storage root holding one team the learner may edit, and a team Doc
    /// with the shared base body.
    private static func makeTeamDoc() async throws -> (StorageService, KnowledgeStore, String, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TeamDraftPublish_\(UUID().uuidString)", isDirectory: true)
        let storage = StorageService(storeRoot: root)
        let store = try await storage.cohortKnowledgeStore()
        let now = Date()
        try store.saveTeam(TeamRecord(
            id: "team-1",
            name: "Nexus",
            role: .owner,
            permission: .readWrite,
            zoneScope: .privateScope,
            zoneName: TeamRecord.zoneName(forTeamID: "team-1"),
            zoneOwnerRecordName: nil,
            shareRecordName: nil,
            shareURL: nil,
            createdAt: now,
            joinedAt: now,
            updatedAt: now
        ))
        let doc = try await storage.createArtifact(
            title: "Landscape",
            homeNotebookID: nil,
            linkedNotebookIDs: [],
            markdown: base,
            teamID: "team-1"
        )
        return (storage, store, doc.artifact.id, root)
    }

    /// docs/teams-design.md, decision 11: Publish merges the draft into the
    /// team copy against the body the draft was taken from. Every acknowledged
    /// upload of the draft makes its own body the sync base; while that one
    /// sidecar was also the publish base, a Publish after a sync kept the team
    /// body over every edit and deleted the draft (check 7, C7-m11).
    @Test("A team Doc draft that has synced publishes its edits, merged with a teammate's")
    func syncedDraftPublishesItsEdits() async throws {
        let (storage, store, teamDocID, root) = try await Self.makeTeamDoc()
        defer { try? FileManager.default.removeItem(at: root) }
        let draftID = try await storage.beginTeamDocDraft(teamArtifactID: teamDocID)

        let draftBody = Self.base.replacingOccurrences(of: "Intro paragraph.", with: "A sharper intro.")
        let opened = try await storage.artifactMarkdown(draftID)
        _ = try await storage.writeArtifactMarkdown(
            artifactID: draftID,
            markdown: draftBody,
            expectedRevision: opened.revision
        )
        // The draft's upload is acknowledged: its body becomes the sync base.
        try store.saveArtifactBaseMarkdown(draftBody, artifactID: draftID)

        // Meanwhile a teammate changed another passage of the team copy.
        let teamBody = Self.base.replacingOccurrences(
            of: "Line about the evidence.",
            with: "Line about the newer evidence."
        )
        let current = try await storage.artifactMarkdown(teamDocID)
        _ = try await storage.writeArtifactMarkdown(
            artifactID: teamDocID,
            markdown: teamBody,
            expectedRevision: current.revision
        )

        let published = try await storage.publishTeamDocDraft(
            draftID: draftID,
            teamArtifactID: teamDocID,
            overwrite: false
        )
        #expect(published.markdown.contains("A sharper intro."))
        #expect(published.markdown.contains("Line about the newer evidence."))
        #expect(!published.markdown.contains("Intro paragraph."))
        #expect(try await storage.artifactMarkdown(teamDocID).markdown == published.markdown)
        #expect(try store.loadArtifact(draftID) == nil)
    }

    /// The body a draft was taken from is the Mac's own record. A draft that
    /// arrives from another of the member's Macs has none here, and its sync
    /// base is its own body; it publishes as it stands rather than losing its
    /// text to the team copy.
    @Test("A team Doc draft taken on another Mac publishes as it stands")
    func draftFromAnotherMacPublishesAsItStands() async throws {
        let (storage, store, teamDocID, root) = try await Self.makeTeamDoc()
        defer { try? FileManager.default.removeItem(at: root) }
        let draftID = TeamContentIdentity.draftArtifactID(teamID: "team-1", teamArtifactID: teamDocID)
        let now = Date()
        try store.saveArtifactRecord(ArtifactRecord(
            id: draftID,
            title: "Landscape",
            homeNotebookID: nil,
            linkedNotebookIDs: [],
            isDraft: true,
            teamID: nil,
            createdAt: now,
            updatedAt: now
        ))
        let draftBody = Self.base.replacingOccurrences(of: "Intro paragraph.", with: "Written on the other Mac.")
        try store.saveArtifactMarkdownFromSync(draftBody, artifactID: draftID)
        #expect(try store.loadTeamDraftPublishBaseMarkdown(draftID) == nil)

        let published = try await storage.publishTeamDocDraft(
            draftID: draftID,
            teamArtifactID: teamDocID,
            overwrite: false
        )
        #expect(published.markdown == draftBody)
        #expect(try store.loadArtifact(draftID) == nil)
    }
}
