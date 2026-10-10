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

    /// The doc's page, or nil when it has none or the answer is not available.
    /// Silent by design: it runs when a doc opens, and a Mac that is signed out
    /// or offline simply shows the doc as unpublished.
    func publishedDocStatus(_ artifactID: String) async -> PublishedDocStatus? {
        guard ManagedAI.isSignedIn else { return nil }
        do {
            return try await DocPublishing.status(docID: artifactID)
        } catch {
            Logger(subsystem: "com.foreverlm", category: "DocPublishing")
                .info("Published status unavailable for \(artifactID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
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
    /// stored page replaced and the site republished, every other file, the
    /// address and its readers kept — the same code as `replace_site_text`,
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

    // MARK: - Publishing a site kept in the library

    /// Put a copy of a site or animation on the web — the Sites menu's
    /// Publish to the Web, through the same code as `publish_site`.
    func publishSite(_ artifactID: String, visibility: SitePublishingAccess.Visibility) async {
        do {
            _ = try await MCPDataStore().publishSite(
                site: artifactID, title: nil, html: nil, files: nil,
                repository: nil, repositoryPath: nil, ref: nil, slug: nil,
                visibility: visibility.rawValue,
                homeNotebookID: nil, notebookIDs: []
            )
            await refreshPublishedSiteStatuses()
            showToast(visibility == .publicSite ? "Published to the web" : "Published privately")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Take the published copy down; the site stays in the library.
    func unpublishSite(_ artifactID: String) async {
        do {
            _ = try await MCPDataStore().unpublishSite(site: artifactID)
            publishedSiteStatusesBySlug = publishedSiteStatusesBySlug.filter { $0.value.siteID != artifactID }
            await refreshPublishedSiteStatuses()
            showToast("Unpublished")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Site publishing provenance

    /// Reload the account's Site projection without delaying the local list.
    /// The linked Artifact intentionally stores only the site's canonical URL;
    /// repository, ref, folder and exact commit remain server-owned publishing
    /// state. A transient failure keeps the last known answer, so repository-
    /// backed Sites do not blink between GitHub and the generic web mark while
    /// offline.
    func refreshPublishedSiteStatuses() async {
        guard ManagedAI.isSignedIn else { return }
        // Sites made before 2026-09-22 still live on sites.foreverlm.com;
        // the first visit to Sites signed in brings them into the library.
        if await HostedSiteAdoption.runIfNeeded(storage: storage) {
            await loadArtifacts()
        }
        do {
            let statuses = try await SitePublishing.statuses()
            // By slug for a record still pointing at a hosted address, and by
            // site id — the id of the record it was published from — for a
            // site kept in the library.
            publishedSiteStatusesBySlug = Dictionary(
                statuses.values.flatMap { [($0.slug, $0), ($0.siteID, $0)] },
                uniquingKeysWith: { first, _ in first }
            )
        } catch {
            Logger(subsystem: "com.foreverlm", category: "SitePublishing")
                .info("Published Sites list unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }
}
