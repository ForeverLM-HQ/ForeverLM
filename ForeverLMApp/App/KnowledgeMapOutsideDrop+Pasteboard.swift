import AppKit
import UniformTypeIdentifiers

// MARK: - Reading what the Canvas's web view is handed
//
// A drag onto the Canvas, or ⌘V on it, can carry the Finder's files, a picture
// (raw, or promised by an app such as Screenshots), a chat dragged from a list,
// or an address or words. This reads the pasteboard into
// `KnowledgeMapOutsideDrop`; `StudioViewModel.knowledgeMapOutsideRefs` makes
// cards of it (docs/knowledge-map-design.md, "Dropping from the rest of the
// app").

extension KnowledgeMapOutsideDrop {
    static let chatType = NSPasteboard.PasteboardType(UTType.reviewSession.identifier)

    /// The types the Canvas's web view registers for besides the app's own
    /// cards: files, web addresses, pictures, promised files and chats.
    static let draggedTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, .URL, .png, .tiff, chatType]
        + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    /// The URL schemes this build reads as its own, for a pasted card address.
    static var schemes: Set<String> {
        ["foreverlm", ForeverLMRuntimeIdentity.urlScheme.lowercased()]
    }

    /// What a drag carries from outside the app's own cards. The chats come
    /// first, from the chat lists' own drag; files, pictures and web addresses
    /// are read only when the drag carries none of the app's own cards
    /// (`includingFiles`): a source dragged from the Sources list carries a
    /// file of itself too, and must stay a source.
    init(dragging pasteboard: NSPasteboard, includingFiles: Bool) {
        self.init()
        let decoder = JSONDecoder()
        chatIDs = (pasteboard.pasteboardItems ?? []).compactMap { item in
            item.data(forType: Self.chatType).flatMap { try? decoder.decode(ReviewSessionTransfer.self, from: $0) }?.sessionID
        }
        guard includingFiles, chatIDs.isEmpty else { return }
        fileURLs = Self.fileURLs(on: pasteboard)
        if fileURLs.isEmpty {
            pictures = Self.pictures(on: pasteboard, named: "Dropped picture")
        }
        if fileURLs.isEmpty, pictures.isEmpty {
            links = Self.webAddresses(on: pasteboard)
        }
    }

    /// What ⌘V brings: files copied in the Finder, a picture, or text (an
    /// address, a card's `foreverlm://` address, or words).
    init(pasting pasteboard: NSPasteboard) {
        self.init()
        fileURLs = Self.fileURLs(on: pasteboard)
        if fileURLs.isEmpty {
            pictures = Self.pictures(on: pasteboard, named: "Pasted picture")
        }
        guard fileURLs.isEmpty, pictures.isEmpty else { return }
        if let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add(pastedText: text, schemes: Self.schemes, importableLink: StudioViewModel.importableLink(in:))
        } else {
            links = Self.webAddresses(on: pasteboard)
        }
    }

    private static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return urls.map { ($0 as NSURL).filePathURL ?? $0 }
    }

    private static func pictures(on pasteboard: NSPasteboard, named name: String) -> [Picture] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            let data = item.data(forType: .png) ?? item.data(forType: .tiff)
            return data.flatMap { $0.isEmpty ? nil : Picture(data: $0, name: name) }
        }
    }

    private static func webAddresses(on pasteboard: NSPasteboard) -> [String] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        return urls.compactMap { url in
            url.isFileURL ? nil : StudioViewModel.importableLink(in: url.absoluteString)
        }
    }
}

extension StudioViewModel {
    /// The cards a drop or a paste on a Canvas's web view sets down: the
    /// cards a Library or add-box row carried (the ones this canvas knows),
    /// the app's own (sources, Docs, a notebook with its frame, clips saved as
    /// they land) and what came from outside (`knowledgeMapOutsideRefs`: only what
    /// was imported). Nil when there is nothing to set down, after a toast
    /// saying why, or when the canvas the drop was made on is no longer the
    /// open one by the time an import finished: the cards are then written
    /// into that canvas's row (`addToCanvas`) rather than set down on another.
    func knowledgeMapCards(
        for drop: KnowledgeMapWebView.Drop,
        on map: KnowledgeMapModel
    ) async -> (refs: [String], regionName: String?, notebookID: String?)? {
        // A Library or add-box row names its cards: set down as they are, with
        // no frame, and nothing else the drag carried.
        if !drop.cardRefs.isEmpty {
            let known = drop.cardRefs.filter { map.nodesByRef[$0] != nil }
            guard !known.isEmpty else {
                showToast("Nothing dropped is on the canvas yet")
                return nil
            }
            return (known, nil, nil)
        }
        // A clip is saved as it lands, so the page knows its card.
        let clipRefs = drop.clips.isEmpty ? [] : await knowledgeMapClipRefs(drop.clips)
        let placed = knowledgeMapDrop(sourceIDs: drop.sourceIDs, docIDs: drop.docIDs, notebookIDs: drop.notebookIDs)
        let outsideRefs = drop.outside.isEmpty ? [] : await knowledgeMapOutsideRefs(drop.outside)
        let refs = placed.refs + clipRefs + outsideRefs
        guard !refs.isEmpty else {
            // What came from outside said why in a toast of its own.
            if drop.outside.isEmpty { showToast("Nothing dropped is on the canvas yet") }
            return nil
        }
        guard map.mapID == knowledgeMap.mapID else {
            await addToCanvas(refs: refs, canvasID: map.mapID)
            return nil
        }
        return (refs, placed.regionName, placed.notebookID)
    }
}
