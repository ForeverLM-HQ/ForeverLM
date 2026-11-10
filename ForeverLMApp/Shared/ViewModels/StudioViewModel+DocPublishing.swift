import Foundation
import OSLog

/// Publishing a Doc as a page on foreverlm.com. Spec: docs/docs-design.md → Publishing.
extension StudioViewModel {
    /// All pages this account owns, for the Docs list. Publication stays server
    /// state rather than library metadata, so an unavailable projection is an
    /// empty one and never delays the local library.
    func publishedDocStatuses() async -> [String: PublishedDocStatus] {
        guard ManagedAI.isSignedIn else { return [:] }
        do {
            return try await DocPublishing.statuses()
        } catch {
            Logger(subsystem: "com.foreverlm", category: "DocPublishing")
                .info("Published Docs list unavailable: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    /// Reload the projection into `publishedDocStatuses`. An unavailable
    /// answer keeps what is held rather than emptying it, so a blink of
    /// network does not move every published page back into Docs.
    func refreshPublishedDocStatuses() async {
        guard ManagedAI.isSignedIn else { return }
        do {
            publishedDocStatuses = try await DocPublishing.statuses()
        } catch {
            Logger(subsystem: "com.foreverlm", category: "DocPublishing")
                .info("Published Docs list unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Publish the stored body, or update the page it already has. The caller
    /// flushes any unsaved draft first so the page and the pane agree.
    func publishDoc(_ artifactID: String, access: DocPageAccess = .keep, slug: String? = nil) async throws -> PublishedDocStatus {
        let snapshot = try await storage.artifactMarkdown(artifactID)
        // Publish sends the body to the library too, not only on idle (generation 2, D44).
        DocBodySync.requestPublish(artifactID)
        guard !snapshot.artifact.isLinked else {
            // The body ForeverLM holds for a Google Doc is a text export, not
            // the document; the page to share is Google's own.
            throw ArtifactError.linkedDocReadOnly(snapshot.artifact.title)
        }
        // A reader outside the app gets the words: block references and
        // embeds as the blocks' text, title links and tags as their words, no
        // block id markers (docs/notes-graph-design.md, "Invariants").
        let markdown = try await storage.docGraphResolvedMarkdown(
            snapshot.markdown,
            teamID: referenceLibraryTeamID(for: snapshot.artifact)
        )
        let status = try await DocPublishing.publish(
            docID: artifactID,
            title: snapshot.artifact.title,
            markdown: markdown,
            access: access,
            slug: slug
        )
        showToast("Published to foreverlm.com")
        return status
    }

    func unpublishDoc(_ artifactID: String) async throws {
        try await DocPublishing.unpublish(docID: artifactID)
        showToast("Unpublished")
    }

    // MARK: - Changing a passage of a Site

    /// The Change action on a selection in an open Site: one passage of the
    /// stored page replaced, every other file kept — the same code as
    /// `replace_site_text`,
    /// so the app and the tool cannot drift (docs/docs-design.md, "Changing a
    /// passage in place"). Returns nil when the change went, or the sentence
    /// to show when it did not: the passage was not found in the page's
    /// source, or appears more than once.
    func replaceSiteText(artifactID: String, pageURL: URL?, find: String, replace: String) async -> String? {
        do {
            _ = try await MCPDataStore().replaceSiteText(
                site: artifactID,
                find: find,
                replace: replace,
                path: pageURL?.absoluteString
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
