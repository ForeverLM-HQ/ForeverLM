import Foundation
#if os(macOS)
import AppKit
#endif

// MARK: - Publish a canvas as a site page
//
// Heptabase publishes a whiteboard at a live public link
// (docs/heptabase-canvas-parity.md, "Sharing, export, platforms"). A canvas
// is the learner's own layout row, so it publishes as a site of one page
// through the Sites pipeline (docs/docs-design.md, "Sites made in
// ForeverLM"; docs/knowledge-map-design.md, "Versions, export and
// publishing"): the canvas drawn as a picture at 2× at the head
// (`canvas.png`), under it the outline of its cards (`KnowledgeMapOutline`),
// a card a web address is known for as a link. The site is an entry in the
// learner's own library, named after the canvas and filed in no notebook, so
// no team ever holds it (a team has no canvases of its own yet); its id is
// written on the canvas's row (`KnowledgeMapLayout.site`) so Publish Changes
// renders over the same entry and another Mac knows which it is. Saving it
// through `save_site` republishes it if it is up; `publish_site` puts the
// first copy on the web, private unless the learner says public, as Sites
// always do.

/// Why a canvas could not be published.
enum CanvasPublishError: LocalizedError, Equatable {
    case signedOut
    case inATeamLibrary
    /// A first publish with no choice of who may open it.
    case visibilityNeeded
    /// Even the smallest picture is over a site's file limit.
    case pictureTooLarge(name: String)
    case malformedAnswer
    /// The save went through but the page could not be put on the web.
    case publishFailed(String)

    var errorDescription: String? {
        switch self {
        case .signedOut:
            return MCPDataStore.siteSignedOutMessage
        case .inATeamLibrary:
            return "A canvas is yours alone: switch to My Library to publish it."
        case .visibilityNeeded:
            return "Choose who can open the page, private or public, before the first publish."
        case .pictureTooLarge(let name):
            return "‘\(name)’ is too large to publish as a picture, even drawn small. Publish the part you mean to show: take the rest off the canvas, or move it to another."
        case .malformedAnswer:
            return "The site could not be read back after it was saved."
        case .publishFailed(let message):
            return message
        }
    }
}

extension StudioViewModel {
    /// The Sites entry a canvas is published as, when it has one.
    func canvasSiteID(_ canvasID: String) -> String? {
        currentCanvasLayout(canvasID).site?.id.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// What the web holds for the canvas: its page, when it is up.
    func publishedCanvasStatus(_ canvasID: String) -> PublishedSiteStatus? {
        canvasSiteID(canvasID).flatMap { publishedSiteStatusesBySlug[$0] }
    }

    /// Where a card leads on the page: its public address, when one is
    /// known. A source (and a figure or page cut from one) is the address the
    /// library records for sharing; a page of the learner's, the one it is
    /// published at, when anyone with the link may read it. An Idea, a chat
    /// and the rest have none.
    func canvasPublicLink(for node: KnowledgeMapNode) -> String? {
        canvasPublicLinks()(node)
    }

    /// `canvasPublicLink(for:)` for many cards: the library's sources read
    /// once, not once a card.
    func canvasPublicLinks() -> (KnowledgeMapNode) -> String? {
        let sources = Dictionary(articles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pages = publishedDocStatuses
        let sites = publishedSiteStatusesBySlug
        return { node in
            func sourceLink(_ sourceID: String) -> String? {
                sources[sourceID].flatMap(SiteSourceCards.publicURL(for:))
            }
            let ref = node.ref
            guard let colon = ref.firstIndex(of: ":") else { return nil }
            let id = String(ref[ref.index(after: colon)...])
            switch KnowledgeMapMarkdown.kind(of: ref) {
            case "source":
                return sourceLink(id)
            case "clip", "page":
                guard let src = node.src, src.hasPrefix("source:") else { return nil }
                return sourceLink(String(src.dropFirst("source:".count)))
            case "doc":
                if let page = pages[id], !page.isProtected { return page.url.absoluteString }
                if let site = sites[id], site.access?.visibility == .publicSite { return site.url.absoluteString }
                return nil
            default:
                return nil
            }
        }
    }

    /// The canvas drawn as the page's picture: 2× when it fits a site's file
    /// limit, else the largest of the smaller scales that does.
    func canvasHeroPicture(canvasID: String) async throws -> (data: Data, scale: Double) {
        for scale in CanvasExport.publishScales {
            let data = try await exportCanvasImageData(canvasID: canvasID, scale: scale)
            if data.count <= SitePublishing.maxFileBytes { return (data, scale) }
        }
        throw CanvasPublishError.pictureTooLarge(name: canvasDisplayName(canvasID))
    }

    /// **Publish… / Publish Changes**: the canvas rendered as a page and
    /// saved into its Sites entry (made now, the first time), then put on the
    /// web: a first publish at `visibility`, which it needs; an update keeps
    /// the live one, and `visibility` is then left out. Returns what the web
    /// holds afterwards. The canvas must be the open one in a Canvas pane,
    /// which draws its picture.
    @discardableResult
    func publishCanvas(canvasID: String, visibility: SitePublishingAccess.Visibility? = nil) async throws -> PublishedSiteStatus {
        guard ManagedAI.isSignedIn else { throw CanvasPublishError.signedOut }
        guard activeTeamID == nil else { throw CanvasPublishError.inATeamLibrary }
        let name = canvasDisplayName(canvasID)
        let picture = try await canvasHeroPicture(canvasID: canvasID)
        if knowledgeMap.content.nodes.isEmpty { await refreshKnowledgeMapContent() }
        await refreshPublishedSiteStatuses()
        await refreshPublishedDocStatuses()

        let model = knowledgeMap
        let outline = KnowledgeMapMarkdown.outline(
            layout: model.layout,
            nodes: model.nodesByRef,
            cardSize: { ref in (KnowledgeMap.cardWidth, model.cardHeight(of: ref)) },
            linkFor: canvasPublicLinks()
        )
        let page = KnowledgeMapSitePage.html(title: name, outline: outline)

        let store = MCPDataStore()
        var siteID = canvasSiteID(canvasID)
        // The entry may have been deleted from Sites since: make another.
        if let known = siteID, try await store.existingSiteArtifact(handle: known) == nil { siteID = nil }
        let saved = try await store.saveSite(
            site: siteID,
            title: name,
            html: nil,
            files: [
                ["path": SitePublishing.entryFile, "content": page],
                ["path": KnowledgeMapSitePage.imagePath, "content_base64": picture.data.base64EncodedString()],
            ],
            repository: nil,
            repositoryPath: nil,
            ref: nil,
            removeFiles: [],
            replaceAll: true,
            homeNotebookID: nil,
            notebookIDs: []
        )
        guard let answer = (try? JSONSerialization.jsonObject(with: Data(saved.utf8))) as? [String: Any],
              let savedID = answer["site_id"] as? String else { throw CanvasPublishError.malformedAnswer }
        if let failure = answer["publish_error"] as? String { throw CanvasPublishError.publishFailed(failure) }
        rememberCanvasSite(savedID, for: canvasID)
        // A save of a site that is up republishes it; one that is not is put
        // on the web now.
        let first = answer["published_url"] == nil
        if first {
            // A page the web already holds keeps the choice it has.
            guard let chosen = visibility ?? publishedSiteStatusesBySlug[savedID]?.access?.visibility else {
                throw CanvasPublishError.visibilityNeeded
            }
            _ = try await store.publishSite(
                site: savedID,
                title: nil,
                html: nil,
                files: nil,
                repository: nil,
                repositoryPath: nil,
                ref: nil,
                slug: nil,
                visibility: chosen.rawValue,
                homeNotebookID: nil,
                notebookIDs: []
            )
        }
        await refreshPublishedSiteStatuses()
        guard let status = publishedSiteStatusesBySlug[savedID] else { throw CanvasPublishError.malformedAnswer }
        let message = first
            ? (status.access?.visibility == .publicSite ? "Published to the web" : "Published privately")
            : "Published the changes"
        #if os(macOS)
        let address = status.url.absoluteString
        showToast(message, action: StudioToastAction(title: "Copy Link") { _ in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(address, forType: .string)
        })
        #else
        showToast(message)
        #endif
        return status
    }

    /// **Unpublish**: the page comes off the web and its link stops working.
    /// The Sites entry stays in the library (Publish… puts it up again at a
    /// link of its own), as it does for any site.
    func unpublishCanvas(canvasID: String) async throws {
        guard let siteID = canvasSiteID(canvasID) else { return }
        _ = try await MCPDataStore().unpublishSite(site: siteID)
        publishedSiteStatusesBySlug = publishedSiteStatusesBySlug.filter { $0.value.siteID != siteID }
        await refreshPublishedSiteStatuses()
        showToast("Unpublished")
    }

    /// Writes the entry's id on the canvas's row (merged with the other
    /// Macs', newer wins), unless it is already there.
    private func rememberCanvasSite(_ siteID: String, for canvasID: String, now: Date = Date()) {
        guard canvasSiteID(canvasID) != siteID else { return }
        let stamp = now.timeIntervalSince1970
        let layout = KnowledgeMapRows.update(mapID: canvasID, now: now) { row in
            row.site = .init(id: siteID, at: stamp)
        }
        canvases = canvases.setting(layout, for: canvasID)
        if knowledgeMap.mapID == canvasID { knowledgeMap.reloadLayout() }
    }
}
