import Foundation
import ImageIO
#if canImport(PDFKit)
import PDFKit
#endif

/// The Map's routes in and out of the rest of the app
/// (docs/knowledge-map-design.md).
extension StudioViewModel {
    /// The Map in `destinationWindowState` (the window in scope when nil): the
    /// rail's Map row and the chat's lens tools. A notebook the window holds
    /// leaves the way it does for the Library (`.knowledgeMap` routes `.leave`).
    func openKnowledgeMap(in destinationWindowState: StudioWindowState? = nil) {
        activateCenterTab(.knowledgeMap, in: destinationWindowState ?? activeWindowState)
    }

    /// Whether any window shows the Map.
    var knowledgeMapIsOnScreen: Bool {
        StudioWindowRegistry.shared.states.contains { state in
            state.centerTabGroups.groups.contains { $0.activeTab == .knowledgeMap }
        }
    }

    /// What the cards change with, cheap to compare: the Map pane rebuilds its
    /// cards when this moves.
    var knowledgeMapContentSignature: String {
        let ideaStamp = ideas.map(\.updatedAt.timeIntervalSince1970).max() ?? 0
        let notebookStamp = learningGoals.map(\.updatedAt.timeIntervalSince1970).max() ?? 0
        return [
            "\(articles.count)", "\(articles.first?.id ?? "")", "\(articles.last?.id ?? "")",
            "\(ideas.count)", "\(ideaStamp)",
            "\(learningGoals.count)", "\(notebookStamp)",
            // A box ticked or unticked changes what a notebook's frame holds.
            "\(notebookChatExclusions.hashValue)",
            "\(reviewSessionLinks.count)", "\(artifacts.count)",
            "\(knowledgeMapClipRevision)",
            // A page card placed or taken off (`KnowledgeMapModel.placedPagesStamp`).
            "\(knowledgeMap.placedPagesStamp)",
            // Another canvas made, renamed, trashed or written, and the Images
            // library changed: the shortcut and picture cards.
            "\(knowledgeMapShortcutCanvases.map { "\($0.id)\($0.name)\($0.cardCount)\($0.regionCount)" }.joined().hashValue)",
            "\(knowledgeMap.picturesRevision)",
        ].joined(separator: "|")
    }

    /// The other canvases the open one can hold a shortcut card to: those the
    /// Space lists, not in Trash, not the open one.
    var knowledgeMapShortcutCanvases: [KnowledgeMapCanvas] {
        listedCanvases.filter { !$0.isTrashed && $0.id != knowledgeMap.mapID }
    }

    /// The Images library as picture cards: each image's name and shape, and
    /// the file its picture is drawn from. The store is read again only when
    /// its folder changed (`GeneratedImageStore.folderStamp`), and a picture's
    /// shape is read from its file once. A team's library holds none (the
    /// pictures are this Mac's files).
    private func knowledgeMapPictureCards() async -> [KnowledgeMapPictureCard] {
        guard activeTeamID == nil else { return [] }
        let map = knowledgeMap
        // The notices counted before the read are the ones it already holds; one that lands
        // while it runs is read again next time.
        let revision = map.picturesRevision
        let stamp = await Task.detached(priority: .utility) { GeneratedImageStore.folderStamp() }.value
        if let library = map.pictureLibrary, library.stamp == stamp, library.revision == map.picturesRevision {
            return library.cards
        }
        let groups = await GeneratedImageActions.loadDrawn()
        let known = Dictionary((map.pictureLibrary?.cards ?? []).compactMap { card in
            card.path.flatMap { path in card.aspect.map { (path, $0) } }
        }, uniquingKeysWith: { first, _ in first })
        let paths = groups.map { $0.latest.path }
        let read: [String: Double] = await Task.detached(priority: .utility) {
            var shapes: [String: Double] = [:]
            for path in paths where known[path] == nil {
                if let aspect = Self.imageAspect(atPath: path) { shapes[path] = aspect }
            }
            return shapes
        }.value
        let cards = groups.map { group -> KnowledgeMapPictureCard in
            let path = group.latest.path
            return KnowledgeMapPictureCard(
                imageID: group.imageID,
                title: GeneratedImageActions.title(for: group),
                aspect: known[path] ?? read[path],
                path: path
            )
        }
        map.pictureLibrary = (stamp: stamp, revision: revision, cards: cards)
        return cards
    }

    /// A picture file's width over its height, from its header alone.
    nonisolated private static func imageAspect(atPath path: String) -> Double? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        return width / height
    }

    /// Rebuilds the Map's cards from the library on this Mac, with each
    /// source's first highlight read in one query.
    func refreshKnowledgeMapContent() async {
        let sources = articles.filter { $0.status == .active && !$0.isHidden }
        var firstHighlights: [String: String] = [:]
        var clips: [SourceHighlight] = []
        let notebookSources: Set<String> = openCanvas?.notebookID
            .flatMap { notebook(id: $0)?.approvedSourceIDs }
            .map { Set($0.map(canonicalSourceID)) } ?? []
        do {
            let highlights = try await storage.sourceHighlights(sourceIDs: sources.map(\.id))
            for (sourceID, list) in highlights {
                let quote = list.lazy
                    .map { $0.quote.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty }
                if let quote { firstHighlights[sourceID] = String(quote.prefix(240)) }
                // Clips are filed under the id the source is shown by.
                for clip in list where ReaderClip.isClip(clip) {
                    clips.append(ReaderClip.filed(clip, under: sourceID))
                }
                // A passage is a card once it is on a canvas, was just made for
                // one, or is in a source of the open canvas's notebook, whose
                // tray offers it. Not every highlight in the library.
                for mark in list where ReaderClip.isPassage(mark) {
                    let ref = KnowledgeMap.ItemRef(kind: .clip, id: mark.id).description
                    if knowledgeMap.layout.placements[ref] != nil
                        || knowledgeMap.pendingPassageIDs.contains(mark.id)
                        || notebookSources.contains(sourceID) {
                        clips.append(ReaderClip.filed(mark, under: sourceID))
                    }
                }
            }
        } catch {
            // A card shows without its highlight rather than the Map without
            // its cards; the failure is logged, not hidden.
            logger.error("Canvas could not read highlights: \(error.localizedDescription)")
        }
        await findPassagePages(for: clips)
        await loadKnowledgeMapPageShapes()
        let captions = await knowledgeMapFigureCaptions(for: clips)
        var groupTitles: [String: String] = [:]
        var origins: [String: SourceArtwork.Origin] = [:]
        for source in sources {
            if let group = source.parentGroup, groupTitles[group] == nil, let title = groupDisplayTitle(group) {
                groupTitles[group] = title
            }
            // Cached-only lookups on the main actor, as the Library rows make them.
            if let origin = SourceArtwork.origin(for: source) {
                origins[KnowledgeMap.ItemRef(kind: .source, id: source.id).description] = origin
            }
        }
        // Pictures of the Images library: drawn from their own files.
        let pictures = await knowledgeMapPictureCards()
        for picture in pictures {
            if let path = picture.path { origins[picture.ref] = .file(path) }
        }
        knowledgeMap.artworkOrigins = origins
        if knowledgeMap.clipPicture == nil {
            knowledgeMap.clipPicture = { [weak self] clip in await self?.knowledgeMapClipPicture(clip) }
        }
        if knowledgeMap.pagePicture == nil {
            knowledgeMap.pagePicture = { [weak self] sourceID, page in await self?.knowledgeMapPagePicture(sourceID: sourceID, page: page) }
        }
        knowledgeMap.rebuildContent(
            articles: sources,
            ideas: ideas,
            notebooks: notebooks,
            chats: reviewSessionLinks,
            artifacts: artifacts,
            firstHighlights: firstHighlights,
            groupTitles: groupTitles,
            unticked: notebookChatExclusions,
            clips: clips.sorted { $0.createdAt < $1.createdAt },
            passagePages: knowledgeMap.passagePages,
            pages: knowledgeMap.pageRefs.map { ref in
                KnowledgeMapPageCard(ref: ref, aspect: knowledgeMap.pageAspects[ref].flatMap { $0 > 0 ? $0 : nil })
            },
            captions: captions,
            canvases: knowledgeMapShortcutCanvases,
            pictures: pictures
        )
        knowledgeMap.linkNotebookRegions()
        knowledgeMap.takeUntickedOffFrames(notebookChatExclusions)
    }

    /// The printed caption of the figure each clip was cut from, by highlight
    /// id: the words after its label ("Atlas of lysosomal changes during
    /// aging…"), read from the paper's figure index (a database read; no
    /// model and no PDF). A clip is its figure when its name starts with the
    /// figure's label ("Figure 2", "Figure 2B"); the longest label wins. A
    /// clip that names no figure has no caption.
    private func knowledgeMapFigureCaptions(for clips: [SourceHighlight]) async -> [String: String] {
        var captions: [String: String] = [:]
        let figureClips = clips.filter { ReaderClip.isClip($0) && ReaderClip.page(of: $0) != nil }
        for (sourceID, group) in Dictionary(grouping: figureClips, by: \.sourceID) {
            guard let figures = try? await storage.paperFigures(sourceID: sourceID), !figures.isEmpty else { continue }
            for clip in group {
                let name = ReaderClip.title(of: clip).lowercased()
                guard let figure = figures
                    .filter({ name.hasPrefix($0.figureLabel.lowercased()) })
                    .max(by: { $0.figureLabel.count < $1.figureLabel.count })
                else { continue }
                let words = PaperWalkthroughWriting.displayCaption(
                    for: figure, in: figures,
                    label: \.figureLabel, pageIndex: \.pageIndex, caption: \.caption
                )
                if let title = PaperFigureCaptionTitle.title(from: words), !title.isEmpty {
                    captions[clip.id] = title
                }
            }
        }
        return captions
    }

    /// The page of each passage card whose mark has no page geometry, found
    /// by searching the paper's own PDF for its first words, once, off the
    /// main actor (reading the PDF may pull it down from iCloud).
    private func findPassagePages(for clips: [SourceHighlight]) async {
        #if canImport(PDFKit)
        let wanted: [(id: String, quote: String, article: StudioArticle)] = clips.compactMap { clip in
            guard ReaderClip.isPassage(clip), clip.pdfAnchor == nil, knowledgeMap.passagePages[clip.id] == nil,
                  let article = articlesById[clip.sourceID] else { return nil }
            return (clip.id, clip.quote, article)
        }
        guard !wanted.isEmpty else { return }
        let found: [String: Int] = await Task.detached(priority: .utility) {
            // 0 is "searched, not found", so a refresh does not search again.
            var pages: [String: Int] = Dictionary(uniqueKeysWithValues: wanted.map { ($0.id, 0) })
            var documents: [String: PDFDocument] = [:]
            for item in wanted {
                // Resolving the path stats an iCloud-backed file: here, off the main actor.
                guard let path = item.article.resolvedPDFPath else { continue }
                let document = documents[path] ?? PDFDocument(url: URL(fileURLWithPath: path))
                guard let document else { continue }
                documents[path] = document
                let words = item.quote.split(whereSeparator: \.isWhitespace).prefix(12).joined(separator: " ")
                guard !words.isEmpty,
                      let page = document.findString(words, withOptions: [.caseInsensitive]).first?.pages.first else { continue }
                let index = document.index(for: page)
                if index != NSNotFound { pages[item.id] = index + 1 }
            }
            return pages
        }.value
        for (id, page) in found { knowledgeMap.passagePages[id] = page }
        #endif
    }

    /// Writes the summaries the Map is missing: each cluster whose cards
    /// changed since its summary was written. Waits for the learner to stop
    /// moving things first, asks once for a burst of moves, and stops at the
    /// daily background AI cap.
    func refreshKnowledgeMapSummaries() async {
        let map = knowledgeMap
        let request = map.beginSummaryRequest()
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
        guard map.isLatestSummaryRequest(request) else { return }
        let stale = map.staleClusters()
        guard !stale.isEmpty else { return }
        guard let config = KeychainService.resolveConfig(for: .mapSummaries) else {
            logger.info("Canvas summaries wait: \(KeychainService.backgroundAIUnavailableMessage(for: .mapSummaries) ?? "no Canvas Summaries model is set up")")
            return
        }
        guard await backgroundAIBudget.check().allowsBackgroundSpend else {
            logger.info("Canvas summaries wait for tomorrow: the daily background AI limit is reached")
            return
        }
        var start = 0
        while start < stale.count {
            let batch = Array(stale[start..<min(start + KnowledgeMapSummaries.clustersPerCall, stale.count)])
            start += batch.count
            do {
                let written = try await aiService.knowledgeMapClusterSummaries(batch, config: config)
                guard map.isLatestSummaryRequest(request) else { return }
                map.storeSummaries(written)
            } catch {
                logger.error("Canvas summaries failed: \(error.localizedDescription)")
                return
            }
        }
    }

    /// Writes the caption for what is on screen, once the learner has paused
    /// on it, when they asked for captions. A view seen before reuses its
    /// caption; panning on cancels the one being written.
    func refreshKnowledgeMapViewCaption() async {
        let map = knowledgeMap
        guard map.describesView else { return }
        let key = map.viewport.captionKey
        if let cached = map.cachedCaption(for: key) {
            map.viewCaption = cached
            return
        }
        do { try await Task.sleep(for: .milliseconds(1400)) } catch { return }
        let view = map.captionView()
        guard !view.cards.isEmpty || !view.regions.isEmpty else {
            map.viewCaption = nil
            return
        }
        guard let config = KeychainService.resolveConfig(for: .mapSummaries) else {
            map.viewCaption = KeychainService.backgroundAIUnavailableMessage(for: .mapSummaries)
                ?? "Set up AI in Settings to describe the view."
            return
        }
        guard await backgroundAIBudget.check().allowsBackgroundSpend else {
            map.viewCaption = "The daily background AI limit is reached; captions resume tomorrow."
            return
        }
        do {
            let caption = try await aiService.knowledgeMapViewCaption(view, config: config)
            guard !Task.isCancelled else { return }
            map.setCaption(caption, for: key)
        } catch {
            guard !Task.isCancelled else { return }
            logger.error("Canvas caption failed: \(error.localizedDescription)")
            map.viewCaption = "Could not describe this view: \(error.localizedDescription)"
        }
    }

    /// A card's double-click: a source opens in the Reader, a Doc where Docs
    /// open, an Idea in Ideas, a shortcut card opens that canvas, a chat opens
    /// beside the Canvas, a picture is shown where the Space lists Images.
    func openKnowledgeMapItem(_ ref: String, in windowState: StudioWindowState) async {
        guard let item = KnowledgeMap.ItemRef(ref) else { return }
        switch item.kind {
        case .source:
            await selectArticle(item.id, in: windowState, revealingReader: true)
        case .doc:
            revealArtifact(item.id, in: windowState)
        case .idea:
            openIdeasInReader(in: windowState)
        case .clip:
            await openKnowledgeMapClip(item.id, in: windowState)
        case .page:
            if let parts = item.pageParts {
                await openKnowledgeMapPage(sourceID: parts.sourceID, page: parts.page, in: windowState)
            }
        case .canvas:
            // A canvas gone since the card was set down says so, and stays.
            refreshCanvasesFromRows()
            guard canvases.canvas(item.id) != nil else {
                showToast("That canvas is no longer there")
                return
            }
            openCanvas(item.id, in: windowState)
        case .chat:
            // As a mark's linked chat opens: the chat comes on screen beside
            // the Canvas, and the chat is the one resumed in it.
            inWindow(windowState) {
                revealChat(beside: .knowledgeMap)
                requestResumeReviewSession(item.id)
            }
        case .picture:
            windowState.spaceDestinationKey = SpaceDestination.images.key
            openArtifactsInReader(in: windowState)
        }
    }

    /// ⌘⌫ on the Canvas: an Idea is archived (it leaves the plane and the open
    /// list, and Ideas holds it under Archived to bring back or delete for
    /// good: Ideas have no Trash of their own), and any other card is taken
    /// off the Canvas, as ⌫ does. Nothing else is deleted from the library.
    func deleteKnowledgeMapItems(_ refs: [String]) async {
        let items = refs.compactMap(KnowledgeMap.ItemRef.init)
        let ideaIDs = items.filter { $0.kind == .idea }.map(\.id)
        let others = items.filter { $0.kind != .idea }.map(\.description)
        knowledgeMap.unplace(others)
        for id in ideaIDs {
            guard let idea = ideas.first(where: { $0.id == id }), idea.status == .open else { continue }
            await setIdeaStatus(ideaID: id, status: .archived)
        }
        knowledgeMap.selection.removeAll { ref in refs.contains(ref) }
    }

    /// What a drop from elsewhere in the app puts on the Map: the sources and
    /// Docs dragged, and for a notebook its ticked sources and what it made, under a
    /// region that is the notebook's frame (named after it, linked to it) when
    /// the notebook is all that was dropped.
    func knowledgeMapDrop(sourceIDs: [String], docIDs: [String], notebookIDs: [String]) -> (refs: [String], regionName: String?, notebookID: String?) {
        var refs: [String] = []
        var seen: Set<String> = []
        func add(_ ref: KnowledgeMap.ItemRef) {
            let key = ref.description
            if seen.insert(key).inserted { refs.append(key) }
        }
        for id in sourceIDs { add(.init(kind: .source, id: canonicalSourceID(id))) }
        for id in docIDs { add(.init(kind: .doc, id: id)) }
        var droppedNotebooks: [LearningGoalRecord] = []
        for id in notebookIDs {
            guard let notebook = notebook(id: id) else { continue }
            droppedNotebooks.append(notebook)
            let unticked = notebookChatExclusions[id] ?? []
            for sourceID in notebook.approvedSourceIDs where !unticked.contains(sourceID) { add(.init(kind: .source, id: sourceID)) }
            for artifact in artifacts where artifact.homeNotebookID == id || artifact.linkedNotebookIDs.contains(id) {
                add(.init(kind: .doc, id: artifact.id))
            }
        }
        let framed = sourceIDs.isEmpty && docIDs.isEmpty && droppedNotebooks.count == 1 ? droppedNotebooks.first : nil
        return (refs.filter { knowledgeMap.nodesByRef[$0] != nil }, framed.map { NotebookTitle($0.title).text }, framed?.id)
    }

    /// Sources or Docs dropped on a placed Idea become its evidence: linked
    /// to the Idea (listed in Ideas too), and drawn under it on the Map.
    func linkKnowledgeMapEvidence(ideaRef: String, refs: [String]) async {
        guard let idea = KnowledgeMap.ItemRef(ideaRef), idea.kind == .idea else { return }
        let items = refs.compactMap(KnowledgeMap.ItemRef.init)
        // A clip dropped on an Idea links the paper it was cut from as the
        // Idea's evidence, and is set down just under the Idea, side by side:
        // the figure beside the thought it bears on.
        let clipRefs = items.filter { $0.kind == .clip }.map(\.description)
        let clipSources = items.filter { $0.kind == .clip }.compactMap { knowledgeMap.clips[$0.id]?.sourceID }
        let sourceIDs = items.filter { $0.kind == .source }.map(\.id) + clipSources
        let docIDs = items.filter { $0.kind == .doc }.map(\.id)
        if !sourceIDs.isEmpty { await linkIdea(ideaID: idea.id, kind: .source, targetIDs: Array(Set(sourceIDs)).sorted()) }
        if !docIDs.isEmpty { await linkIdea(ideaID: idea.id, kind: .artifact, targetIDs: docIDs) }
        await refreshKnowledgeMapContent()
        if !clipRefs.isEmpty, let spot = knowledgeMap.layout.placements[ideaRef] {
            let y = spot.y + KnowledgeMap.cardHeight + 30
            knowledgeMap.place(clipRefs.enumerated().map { index, ref in
                (ref: ref, x: spot.x + Double(index) * (KnowledgeMap.cardWidth + 30), y: y)
            })
        }
    }

    /// Writes a note where the learner clicked: an Idea (the learner's own
    /// thought, listed in Ideas too) placed on the Map at that spot.
    func createKnowledgeMapNote(_ text: String, at spot: (x: Double, y: Double)) async {
        guard let idea = await createIdea(title: text) else { return }
        await refreshKnowledgeMapContent()
        knowledgeMap.place([(ref: KnowledgeMap.ItemRef(kind: .idea, id: idea.id).description, x: spot.x, y: spot.y)])
    }

    /// What `createKnowledgeMapIdea` made: the card's ref, and whether it was made
    /// empty for the learner to type into (the title it wears until then is
    /// `knowledgeMapNewIdeaTitle`, and the page forgets it if it is left empty).
    struct KnowledgeMapNewIdea: Equatable {
        var ref: String
        var fresh: Bool
    }

    /// The title an Idea made empty for typing wears until it is written: an
    /// Idea needs at least a few words.
    static let knowledgeMapNewIdeaTitle = "New idea"

    /// A new Idea from the Canvas's own editor (the words the learner wrote on
    /// the plane), a mind map's Return or Tab (empty, for typing into), or an
    /// option-drag copy of another Idea: made, placed at `spot`, and, in a mind
    /// map, joined to its parent by a branch.
    ///
    /// - `parentRef`: the Idea it hangs from; it is set a column to the right of
    ///   it, after the parent's other children, and the branch is drawn.
    /// - `after`: the Idea it follows (a sibling in a mind map): set just under
    ///   it in the order the tree reads, which is the order of the stored spots.
    /// - `regionID`: the region it is in, grown to hold it.
    /// - `copyOf`: an Idea whose title and note it takes.
    @discardableResult
    func createKnowledgeMapIdea(
        title: String,
        note: String?,
        at spot: (x: Double, y: Double),
        parentRef: String? = nil,
        after: String? = nil,
        regionID: String? = nil,
        copyOf: String? = nil
    ) async -> KnowledgeMapNewIdea? {
        let map = knowledgeMap
        var words = (title: title, note: note)
        if let copyOf, let source = KnowledgeMap.ItemRef(copyOf), source.kind == .idea,
           let idea = ideas.first(where: { $0.id == source.id }) {
            words = (idea.title, idea.notes)
        }
        let fresh = IdeaRecord.normalizedTitle(words.title).isEmpty
        let written = words.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let idea = await createIdea(
            title: fresh ? Self.knowledgeMapNewIdeaTitle : words.title,
            notes: written.isEmpty ? nil : written
        ) else { return nil }
        await refreshKnowledgeMapContent()
        let ref = KnowledgeMap.ItemRef(kind: .idea, id: idea.id).description
        var x = spot.x, y = spot.y
        if let parentRef, let parent = map.layout.placements[parentRef] {
            x = parent.x + (parent.w ?? KnowledgeMap.cardWidth) + 60
            let below = map.treeChildren(of: parentRef).compactMap { map.layout.placements[$0]?.y }
            y = (below.max() ?? (parent.y - 1)) + 1
        } else if let after, let before = map.layout.placements[after] {
            x = before.x
            y = before.y + 0.5
        }
        map.place([(ref: ref, x: x, y: y)])
        if let parentRef { _ = map.addEdge(from: parentRef, to: ref, label: "", tree: true) }
        if let regionID { map.growRegion(regionID, toHold: [ref]) }
        return KnowledgeMapNewIdea(ref: ref, fresh: fresh)
    }

    /// Opens a fresh chat beside the Map with the start of a request typed,
    /// unsent: the chat finds the papers on a topic and lays them out on the
    /// Map as a concepts lens, the learner's to keep or put back.
    func requestKnowledgeMapTopicChat() {
        openChatBesideKnowledgeMap(
            draft: "On my Canvas, zoom in on  and lay the papers out in context: the concepts in the order they connect, each with the papers that bear on it.",
            sourceIDs: nil
        )
    }

    /// Opens a fresh chat beside the Map with the selected sources as its
    /// context and the question typed, unsent, in its composer.
    func requestChatAboutKnowledgeMapSelection(_ refs: [String]) {
        let items = refs.compactMap(KnowledgeMap.ItemRef.init)
        // A page card brings its paper into the chat, named with its page.
        let sourceIDs = items.filter { $0.kind == .source }.map(\.id) + items.compactMap { $0.pageParts?.sourceID }
        let titles = refs.prefix(12).map { ref -> String in
            guard let parts = KnowledgeMap.ItemRef(ref)?.pageParts, let node = knowledgeMap.nodesByRef[ref] else {
                return "“\(knowledgeMap.title(of: ref))”"
            }
            return "“\(node.sub)” page \(parts.page)"
        }
        let draft = refs.count == 1
            ? "On my Canvas I picked \(titles.joined()). "
            : "On my Canvas I circled \(refs.count) cards: \(titles.joined(separator: ", "))\(refs.count > titles.count ? ", and more" : ""). "
        openChatBesideKnowledgeMap(draft: draft, sourceIDs: sourceIDs, selection: refs)
        showToast(Self.addedToChatMessage(refs.count == 1 ? "Card" : "Selection", elsewhere: chatRequestElsewhereNotice))
    }
}
