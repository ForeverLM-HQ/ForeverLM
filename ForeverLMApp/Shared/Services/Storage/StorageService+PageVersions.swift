import Foundation

// MARK: - Where this Mac keeps its pages' versions

extension KnowledgeStore {
    /// This Mac's versions of its pages, in `.appdata/PageHistory` beside the
    /// database (`PageVersionHistory`); nil for a store held in memory.
    var pageVersionHistory: PageVersionHistory? {
        guard dbPath != ":memory:" else { return nil }
        return PageVersionHistory(
            rootDirectory: URL(fileURLWithPath: dbPath)
                .deletingLastPathComponent()
                .appendingPathComponent(PageVersionHistory.folderName, isDirectory: true)
        )
    }
}

// MARK: - Version history and Duplicate, from the page's menu

extension StorageService {
    /// The open page's versions on this Mac, newest first.
    func pageVersions(artifactID: String) throws -> [PageVersion] {
        try notebookFilesKnowledgeStore().pageVersionHistory?.versions(of: artifactID) ?? []
    }

    /// Each of the page's versions' size in bytes, by version id
    /// (`list_doc_versions`).
    func pageVersionByteCounts(artifactID: String, versions: [PageVersion]) throws -> [String: Int] {
        try notebookFilesKnowledgeStore().pageVersionHistory?.byteCounts(of: versions, artifactID: artifactID) ?? [:]
    }

    func pageVersionMarkdown(artifactID: String, version: PageVersion) throws -> String {
        guard let history = try notebookFilesKnowledgeStore().pageVersionHistory else {
            throw ArtifactError.unavailable(artifactID)
        }
        return try history.markdown(of: version, artifactID: artifactID)
    }

    /// **Restore This Version**: the version's body becomes the page's through
    /// the ordinary save, which keeps the body it replaces as a `restore`
    /// version, so the restore is undone from the same list.
    func restorePageVersion(
        artifactID: String,
        version: PageVersion,
        expectedRevision: String
    ) async throws -> ArtifactMarkdownSnapshot {
        let markdown = try pageVersionMarkdown(artifactID: artifactID, version: version)
        return try await writeArtifactMarkdownAndSync(
            artifactID: artifactID,
            markdown: markdown,
            expectedRevision: expectedRevision,
            versionReason: .restore
        )
    }

    /// **Duplicate**: a new page in My Library with the same body, its
    /// attached pictures and files, its notebooks and its draft mark, called
    /// "<title> copy". A team's page is copied out of the team; a linked page
    /// has no body of its own to copy.
    func duplicateArtifact(artifactID: String) throws -> ArtifactMarkdownSnapshot {
        let original = try artifactMarkdown(artifactID)
        guard !original.artifact.isLinked else {
            throw ArtifactError.linkedDocReadOnly(original.artifact.title)
        }
        let copy = try createArtifact(
            title: "\(original.artifact.title) copy",
            homeNotebookID: original.artifact.teamID == nil ? original.artifact.homeNotebookID : nil,
            linkedNotebookIDs: original.artifact.teamID == nil ? original.artifact.linkedNotebookIDs : [],
            markdown: original.markdown,
            isDraft: original.artifact.isDraft,
            teamID: nil,
            sourceIDs: original.artifact.teamID == nil ? original.artifact.sourceIDs : []
        )
        // The body names its pictures and files by token
        // (`foreverlm://attachment/<token>`), which resolve in the page's own
        // folder, so the copy keeps a copy of each.
        let from = try artifactDirectoryURL(artifactID: artifactID, createIfNeeded: false)
            .appendingPathComponent("Attachments", isDirectory: true)
        if FileManager.default.fileExists(atPath: from.path) {
            let to = try artifactDirectoryURL(artifactID: copy.artifact.id, createIfNeeded: true)
                .appendingPathComponent("Attachments", isDirectory: true)
            do {
                try FileManager.default.copyItem(at: from, to: to)
            } catch {
                try? deleteArtifact(copy.artifact.id)
                throw error
            }
        }
        return copy
    }
}
