import Foundation

// A member's private draft of a team Doc: taken from the team copy, edited in
// the member's own library, and published back over the copy when it is ready
// (docs/teams-design.md, decision 11). The team copy reads as a page in
// between, so a half-written change never shows up in a teammate's Docs.
extension StorageService {
    /// Take a draft of a team Doc, or return the one already taken. The draft
    /// is a Doc in My Library under the deterministic draft id, with the team
    /// copy's title, body and pictures, and the team body recorded beside it as
    /// the base the eventual publish merges against. That record is
    /// `document.publish-base.md`, which sync never moves; the team body is
    /// also the draft's first `document.base.md`, the sync base its first
    /// upload replaces, so two of the member's Macs taking the draft at once
    /// merge their bodies against the text both started from.
    func beginTeamDocDraft(teamArtifactID: String) throws -> String {
        let store = try notebookFilesKnowledgeStore()
        guard let teamArtifact = try store.loadArtifact(teamArtifactID),
              let teamID = teamArtifact.teamID else {
            throw ArtifactError.unavailable(teamArtifactID)
        }
        guard !teamArtifact.isLinked else {
            throw ArtifactError.linkedDocReadOnly(teamArtifact.title)
        }
        let draftID = TeamContentIdentity.draftArtifactID(teamID: teamID, teamArtifactID: teamArtifactID)
        if try store.loadArtifact(draftID) != nil { return draftID }

        let snapshot = try artifactMarkdown(teamArtifactID)
        let directory = try artifactDirectoryURL(artifactID: draftID, createIfNeeded: true)
        try Data(snapshot.markdown.utf8).write(
            to: directory.appendingPathComponent("document.md"),
            options: .atomic
        )
        try copyArtifactAttachments(from: teamArtifactID, to: draftID)
        try store.saveTeamDraftPublishBaseMarkdown(snapshot.markdown, draftID: draftID)
        try store.saveArtifactBaseMarkdown(snapshot.markdown, artifactID: draftID)
        let now = Date()
        try store.saveArtifactRecord(ArtifactRecord(
            id: draftID,
            title: teamArtifact.title,
            homeNotebookID: nil,
            linkedNotebookIDs: [],
            isDraft: true,
            teamID: nil,
            createdAt: now,
            updatedAt: now
        ))
        return draftID
    }

    /// Publish a draft over its team copy and delete the draft.
    ///
    /// The team copy may have moved on since the draft began — another member
    /// published, or edited from Web Studio, where a team Doc is still edited
    /// in place. Those changes are merged with the draft's against the body the
    /// draft started from; a merge that cannot be combined throws
    /// `ArtifactError.conflict`, and the caller publishes again with
    /// `overwrite` once the writer has said the draft should stand.
    ///
    /// The body the draft started from is this Mac's own record, never synced.
    /// A draft taken on another of the member's Macs, or before that record
    /// existed, has none here and publishes as it stands, as the draft's text
    /// is the one thing Publish must not lose.
    @discardableResult
    func publishTeamDocDraft(
        draftID: String,
        teamArtifactID: String,
        overwrite: Bool
    ) throws -> ArtifactMarkdownSnapshot {
        let store = try notebookFilesKnowledgeStore()
        let draft = try artifactMarkdown(draftID)
        let team = try artifactMarkdown(teamArtifactID)
        guard team.artifact.teamID != nil else { throw ArtifactError.unavailable(teamArtifactID) }

        var body = draft.markdown
        if !overwrite, let base = try store.loadTeamDraftPublishBaseMarkdown(draftID), base != team.markdown {
            switch ArtifactThreeWayMerge.merge(base: base, mine: draft.markdown, theirs: team.markdown) {
            case .merged(let merged):
                body = merged
            case .conflict:
                throw ArtifactError.conflict(team.artifact.title)
            }
        }

        try copyArtifactAttachments(from: draftID, to: teamArtifactID)
        var published = try writeArtifactMarkdown(
            artifactID: teamArtifactID,
            markdown: body,
            expectedRevision: team.revision
        )
        if draft.artifact.title != team.artifact.title {
            let renamed = try updateArtifact(
                artifactID: teamArtifactID,
                title: draft.artifact.title,
                homeNotebookID: nil,
                linkedNotebookIDs: nil
            )
            published = ArtifactMarkdownSnapshot(
                artifact: renamed,
                markdown: published.markdown,
                revision: published.revision
            )
        }
        try deleteArtifact(draftID)
        return published
    }

    /// Pictures ride the body as attachment files beside it; a draft needs the
    /// team copy's, and the team copy needs any the draft added.
    private func copyArtifactAttachments(from sourceID: String, to targetID: String) throws {
        let source = try artifactDirectoryURL(artifactID: sourceID, createIfNeeded: false)
            .appendingPathComponent("Attachments", isDirectory: true)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let target = try artifactDirectoryURL(artifactID: targetID, createIfNeeded: true)
            .appendingPathComponent("Attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for name in try FileManager.default.contentsOfDirectory(atPath: source.path) {
            let destination = target.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: destination.path) { continue }
            try FileManager.default.copyItem(at: source.appendingPathComponent(name), to: destination)
        }
    }
}
