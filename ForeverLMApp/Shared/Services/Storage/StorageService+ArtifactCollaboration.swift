import Foundation

// A Doc's edits and comments are local writes: the generation-2 outbox triggers send them, to the
// learner's own library or to the Doc space a share made (§9.1, D5). Generation 1 shared a single Doc
// through a CKShare rooted on its record in the old container; that container stayed with the old
// Apple team, so nothing here reads or writes a shared database any more.
extension StorageService {
    /// One save boundary for a Doc's body, kept for the callers that name it.
    func writeArtifactMarkdownAndSync(
        artifactID: String,
        markdown: String,
        expectedRevision: String,
        versionReason: PageVersionReason = .learnerEdit
    ) async throws -> ArtifactMarkdownSnapshot {
        try writeArtifactMarkdown(
            artifactID: artifactID,
            markdown: markdown,
            expectedRevision: expectedRevision,
            versionReason: versionReason
        )
    }

    func addArtifactCommentAndSync(
        artifactID: String,
        authorRecordName: String,
        authorDisplayName: String,
        body: String,
        selection: ArtifactEditorSelection
    ) async throws -> ArtifactCommentRecord {
        try addArtifactComment(
            artifactID: artifactID,
            parentCommentID: nil,
            authorRecordName: authorRecordName,
            authorDisplayName: authorDisplayName,
            body: body,
            selection: selection
        )
    }

    func setArtifactCommentResolvedAndSync(
        _ commentID: String,
        resolved: Bool
    ) async throws {
        try setArtifactCommentResolved(commentID, resolved: resolved)
    }
}

enum ArtifactCollaborationError: LocalizedError {
    case missingBody

    var errorDescription: String? {
        switch self {
        case .missingBody:
            return "The shared Article body is unavailable."
        }
    }
}
