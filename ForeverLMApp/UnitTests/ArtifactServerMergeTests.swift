import Foundation
import Testing
@testable import ForeverLM

/// A team Doc's draft (docs/teams-design.md, decision 12): its identity, and how it publishes. How a
/// body arriving from another Mac merges is `Sync/DocBodyMergeTests`.
@Suite("Team Doc drafts")
struct ArtifactServerMergeTests {
    private static let base = "# Landscape\n\nIntro paragraph.\n\n## Evidence\n\nLine about the evidence.\n"

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
        try store.saveArtifactMarkdownAsSynced(draftBody, artifactID: draftID)
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
