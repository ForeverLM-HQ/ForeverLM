// Drag and drop transfer models, moved out of Models.swift.

import Foundation
import UniformTypeIdentifiers
import CoreTransferable

// MARK: - Drag & Drop Transfer

extension UTType {
    /// Custom UTType for dragging StudioArticle references within the app.
    static let studioArticle = UTType(exportedAs: "com.foreverlm.studio-article")
    /// Custom UTType for dragging a Doc (a Markdown artifact) within the app.
    static let studioArtifact = UTType(exportedAs: "com.foreverlm.studio-artifact")
    /// Custom UTType for dragging a source id fallback within the app.
    static let studioSourceID = UTType(exportedAs: "com.foreverlm.studio-source-id")
    /// Custom UTType for dragging a source group (book / course) within the app.
    static let studioGroup = UTType(exportedAs: "com.foreverlm.studio-group")
    /// Custom UTType for dragging source category tabs within the Studio sidebar.
    static let studioSidebarTab = UTType(exportedAs: "com.foreverlm.studio-sidebar-tab")
    /// Custom UTType for dragging saved/in-app review chat sessions within the app.
    static let reviewSession = UTType(exportedAs: "com.foreverlm.review-session")
    /// Custom UTType for reordering Notebook folders in the Studio navigation rail.
    static let studioNotebook = UTType(exportedAs: "com.foreverlm.studio-notebook")
    /// Custom UTType for reordering Goal rows in the Goals tab, distinct from
    /// the source types a row also takes so a row dropped on a row is a move
    /// and never a source drop.
    static let studioGoal = UTType(exportedAs: "com.foreverlm.studio-goal")
    /// Custom UTType for a clip dragged out of the Reader's PDF: a box round
    /// part of a page, with the source and page it came from
    /// (`StudioClipTransfer`).
    static let studioClip = UTType(exportedAs: "com.foreverlm.studio-clip")
    /// Custom UTType for a card dragged out of the Canvas's Library sidebar or
    /// its add box: the refs of the cards, so the plane sets down exactly
    /// those (`KnowledgeMapCardTransfer`). It rides beside the card's own drag
    /// (a source's, a Doc's, a clip's), which a chat or an Idea still takes.
    static let knowledgeMapCard = UTType(exportedAs: "com.foreverlm.canvas-card")
    /// Custom UTType for a Space place dragged onto the icon strip, which
    /// keeps it there as a shortcut (`StudioRailShortcut`): its key.
    static let studioRailShortcut = UTType(exportedAs: "com.foreverlm.studio-rail-shortcut")
    /// Custom UTType for an icon of the strip dragged up or down its group
    /// to reorder it (`StudioStripEntry`): its key.
    static let studioStripEntry = UTType(exportedAs: "com.foreverlm.studio-strip-entry")
    /// Custom UTType for a row of a notebook's Studio column dragged onto a
    /// pane, which opens that output there (`NotebookOutputDragPayload`): a
    /// token naming the output, read back in this process only.
    static let notebookOutput = UTType(exportedAs: "com.foreverlm.notebook-output")
    /// Custom UTType for a row of the Space sidebar's Pinned dragged onto
    /// another to reorder the pins (`PagePins.rowsAfterMoving`): its id.
    static let spacePin = UTType(exportedAs: "com.foreverlm.space-pin")
    /// Custom UTType for a Board card dragged to another column or another
    /// place in its column (`SpaceBoardDropDelegate`): the task's id.
    static let boardCard = UTType(exportedAs: "com.foreverlm.board-card")
    /// Finder-style web location files for dragging URL-only sources to external apps.
    static let webInternetLocation = UTType(filenameExtension: "webloc")
        ?? UTType(importedAs: "com.apple.web-internet-location")
    /// Kindle ebook files imported through the existing EPUB book pipeline after conversion.
    static let kindleAZW = UTType(filenameExtension: "azw") ?? UTType(importedAs: "com.amazon.azw")
    static let kindleAZW3 = UTType(filenameExtension: "azw3") ?? UTType(importedAs: "com.amazon.azw3")
    static let kindleMOBI = UTType(filenameExtension: "mobi") ?? UTType(importedAs: "com.amazon.mobi")
    static let kindlePRC = UTType(filenameExtension: "prc") ?? UTType(importedAs: "com.mobipocket.prc")
}

/// Transfer payload for dragging articles within the app and to external apps.
/// The codable representation handles in-app drops (tabs, MCP tray, course groups).
/// The file representation lets users drag sources into browsers (Claude, ChatGPT)
/// as if dragging from Finder — PDFs for papers/books, .txt for text content.
struct StudioArticleTransfer: Codable, Transferable {
    let articleId: String
    var articleIds: [String]?
    let title: String
    let sourceType: String
    /// Source URL for URL-only sources. Excluded from in-app codable transfers.
    var url: String?
    /// Local file path for PDF sources (papers, book chapters). Not included in
    /// the codable representation sent to in-app drop targets.
    var localFilePath: String?
    /// Text content for non-paper sources (transcripts, articles). Excluded from
    /// the codable representation to keep in-app transfers lightweight.
    var content: String?

    enum CodingKeys: String, CodingKey {
        case articleId, articleIds, title, sourceType
    }

    static var transferRepresentation: some TransferRepresentation {
        // In-app drops: lightweight JSON with just id/title/sourceType
        CodableRepresentation(contentType: .studioArticle)
        // External apps: actual PDF file for papers/books with a local PDF
        FileRepresentation(exportedContentType: .pdf) { transfer in
            guard let path = transfer.localFilePath,
                  path.lowercased().hasSuffix(".pdf"),
                  let resolved = SourceService.resolveLocalFileURL(path),
                  FileManager.default.fileExists(atPath: resolved.path) else {
                throw CocoaError(.fileNoSuchFile)
            }
            return SentTransferredFile(resolved)
        }
        // External apps: temp .txt for text content (transcripts, articles)
        FileRepresentation(exportedContentType: .plainText) { transfer in
            guard transfer.localFilePath == nil || !transfer.localFilePath!.lowercased().hasSuffix(".pdf"),
                  transfer.sourceType != "paper",
                  let content = transfer.content, !content.isEmpty else {
                throw CocoaError(.fileNoSuchFile)
            }
            let sanitized = String(transfer.title
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: " -")
                .prefix(80))
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(sanitized).txt")
            try content.write(to: tempURL, atomically: true, encoding: .utf8)
            return SentTransferredFile(tempURL)
        }
        // External apps: Finder-style .webloc for URL-only web sources.
        FileRepresentation(exportedContentType: .webInternetLocation) { transfer in
            guard transfer.localFilePath == nil,
                  let url = transfer.url,
                  url.hasPrefix("http://") || url.hasPrefix("https://") else {
                throw CocoaError(.fileNoSuchFile)
            }
            let sanitized = String(transfer.title
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: " -")
                .prefix(80))
            let plist = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n\t<key>URL</key>\n\t<string>\(url)</string>\n</dict>\n</plist>"
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(sanitized).webloc")
            try plist.write(to: tempURL, atomically: true, encoding: .utf8)
            return SentTransferredFile(tempURL)
        }
    }

    init(from article: StudioArticle) {
        self.articleId = article.id
        self.articleIds = nil
        self.title = article.title
        self.sourceType = article.sourceType.rawValue
        self.url = article.url
        self.localFilePath = article.localFilePath
        self.content = article.content
    }

    init(articleId: String, articleIds: [String], title: String, sourceType: String) {
        self.articleId = articleId
        self.articleIds = articleIds
        self.title = title
        self.sourceType = sourceType
        self.url = nil
        self.localFilePath = nil
        self.content = nil
    }

    /// `sourceType` of a transfer that stands for a dragged group.
    static let groupSourceType = "group"

    /// A dragged group (a book row) as the sources it carried, for a
    /// destination that takes sources. Nil for a group that carried none.
    init?(group: StudioGroupTransfer) {
        let ids = (group.sourceIDs ?? []).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let first = ids.first else { return nil }
        self.init(articleId: first, articleIds: ids, title: group.groupName, sourceType: Self.groupSourceType)
    }

    var isGroup: Bool { sourceType == Self.groupSourceType }

    /// The payload for a drag that starts on `article` and carries `draggedIDs`.
    ///
    /// One source travels with its file and URL representations so external
    /// apps can take it. Several travel as the id list alone; the row under the
    /// pointer stays `articleId` for destinations that only take one.
    static func dragging(_ article: StudioArticle, draggedIDs: [String]) -> StudioArticleTransfer {
        var ids = draggedIDs.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if ids.isEmpty { ids = [article.id] }
        guard ids.count > 1 else { return StudioArticleTransfer(from: article) }
        return StudioArticleTransfer(
            articleId: article.id,
            articleIds: ids,
            title: "\(ids.count) sources",
            sourceType: "selection"
        )
    }

    /// Every source this drag picked up, in the order the learner saw them.
    ///
    /// This is the snapshot a destination must act on. List selection and
    /// modifier flags can change while AppKit owns the drag, so a destination
    /// that consults their live values silently collapses a multi-source drop
    /// to the row under the pointer.
    var draggedSourceIDs: [String] {
        if let articleIds, !articleIds.isEmpty { return articleIds }
        return [articleId]
    }
}

/// Transfer payload for dragging a source group (book / course) into planning surfaces.
/// Source IDs are captured when the drag starts so a whole group can be dropped without
/// depending on its name still resolving to the same live view-model state.
struct StudioGroupTransfer: Codable, Transferable {
    let groupName: String
    let sourceIDs: [String]?

    init(groupName: String, sourceIDs: [String]? = nil) {
        self.groupName = groupName
        self.sourceIDs = sourceIDs
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .studioGroup)
    }
}

/// Transfer payload for reordering a Notebook folder in the Studio navigation rail.
/// Identity stays deterministic: the payload carries only the stored Notebook id.
struct StudioNotebookTransfer: Codable, Transferable {
    let notebookID: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .studioNotebook)
    }
}

/// The cards a Canvas Library or add-box row carries to the plane
/// (`UTType.knowledgeMapCard`, own process only): item refs such as
/// `source:<id>` or `idea:<id>`. A Canvas takes the ones its cards know.
struct KnowledgeMapCardTransfer: Codable, Equatable {
    var refs: [String]
}

/// A Goal row on its way to another row's place in the Goals tab.
struct StudioGoalTransfer: Codable, Transferable {
    let goalID: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .studioGoal)
    }
}

/// Transfer payload for dragging a Doc out of the Docs list.
///
/// A chat the doc lands on attaches it by identity, the way the row's "Add to
/// Chat" item does, so the payload carries only the id and the title the drop
/// target names it by — never the body, which `read_doc` reads back from
/// the stored revision.
struct StudioArtifactTransfer: Codable, Transferable, Equatable {
    let artifactID: String
    let title: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .studioArtifact)
    }
}

/// Transfer payload for dragging a review chat/session into planning surfaces.
struct ReviewSessionTransfer: Codable, Transferable {
    let sessionID: String
    let title: String
    let sourceIDs: [String]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .reviewSession)
    }

    init(sessionID: String, title: String, sourceIDs: [String]) {
        self.sessionID = sessionID
        self.title = title
        self.sourceIDs = sourceIDs
    }

    init(from session: ReviewSessionRecord) {
        self.sessionID = session.id
        self.title = session.title
        self.sourceIDs = session.sourceIDs
    }
}
