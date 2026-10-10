import Foundation

/// The page menu's Version History… and Duplicate (docs/docs-design.md,
/// "Version history" and "The page"). Versions are this Mac's
/// (`PageVersionHistory`); every read and write here runs on the storage
/// actor, off the main thread.
extension StudioViewModel {
    func pageVersions(_ artifactID: String) async -> [PageVersion] {
        do {
            return try await storage.pageVersions(artifactID: artifactID)
        } catch {
            logger.error("Reading the versions of page \(artifactID) failed: \(error.localizedDescription)")
            return []
        }
    }

    func pageVersionMarkdown(_ artifactID: String, version: PageVersion) async throws -> String {
        try await storage.pageVersionMarkdown(artifactID: artifactID, version: version)
    }

    /// The version becomes the page; the body it replaces is kept as a
    /// version first, so a restore is undone from the same list.
    func restorePageVersion(
        _ artifactID: String,
        version: PageVersion,
        expectedRevision: String
    ) async throws -> ArtifactMarkdownSnapshot {
        let restored = try await storage.restorePageVersion(
            artifactID: artifactID,
            version: version,
            expectedRevision: expectedRevision
        )
        artifacts = try await loadScopedArtifacts()
        showToast("Restored the version from \(PageVersionLabel.when(version.savedAt))")
        return restored
    }

    /// A copy of the page, in My Library, beside the original; nil when it
    /// could not be made, which the error banner says.
    func duplicateArtifact(_ artifactID: String) async -> ArtifactRecord? {
        do {
            let copy = try await storage.duplicateArtifact(artifactID: artifactID)
            // The copy sits beside the original: in its space, if it has one.
            if let space = pageSpace(ofPage: artifactID) {
                filePages([copy.artifact.id], inPageSpace: space.id)
            }
            // And under its parent, as a sibling; its own subpages stay put.
            if let parentID = pageParents.rawParentID(ofPage: artifactID) {
                artifacts = try await loadScopedArtifacts()
                setPageParent(copy.artifact.id, to: parentID, announce: false)
            }
            artifacts = try await loadScopedArtifacts()
            showToast("Duplicated as ‘\(copy.artifact.title)’")
            return copy.artifact
        } catch {
            logger.error("Duplicating page \(artifactID) failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            return nil
        }
    }
}
