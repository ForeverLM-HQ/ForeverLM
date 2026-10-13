import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

/// Clips: boxes cut out of a PDF page in the Reader (`ReaderClip`), saved as
/// marks on their source, and what the Canvas does with them
/// (docs/knowledge-map-design.md, "Clips").
@MainActor
extension StudioViewModel {
    func readerClipToolChanged(isOn: Bool) {
        readerClipToolIsOn = isOn
    }

    /// Saves a clip as a mark on its source, the instant it is made, as a
    /// highlight is. A clip whose id is saved already (dropped a second time)
    /// is returned as it stands. `announce` says so in a toast, with the way
    /// to the Canvas, whose Library holds it until it is placed.
    @discardableResult
    func saveReaderClip(_ clip: StudioClipTransfer, announce: Bool) async -> SourceHighlight? {
        if let id = clip.highlightID {
            await loadReaderHighlightsIfNeeded(for: clip.sourceID)
            if let existing = highlight(id: id, sourceID: clip.sourceID) { return existing }
        }
        // A passage names a mark that exists; a mark gone since is nothing to save.
        guard !clip.isPassage else { return nil }
        let highlight = clip.highlight()
        applyLocally(highlight)
        do {
            try await storage.saveSourceHighlight(highlight)
        } catch {
            readerHighlights[clip.sourceID]?.removeAll { $0.id == highlight.id }
            showToast("Could not save that clip: \(error.localizedDescription)")
            return nil
        }
        knowledgeMapClipRevision &+= 1
        if announce {
            showToast(
                "Clip saved · it waits in the Canvas's Library",
                action: StudioToastAction(title: "Open Canvas") { [weak self] window in
                    self?.openKnowledgeMap(in: window)
                }
            )
        }
        return highlight
    }

    /// Clips dropped on the Canvas: each saved (once), the cards read again so
    /// the page knows them, and their refs handed back to place.
    func knowledgeMapClipRefs(_ clips: [StudioClipTransfer]) async -> [String] {
        var refs: [String] = []
        for clip in clips {
            guard let saved = await saveReaderClip(clip, announce: false) else { continue }
            if ReaderClip.isPassage(saved) { knowledgeMap.pendingPassageIDs.insert(saved.id) }
            refs.append(KnowledgeMap.ItemRef(kind: .clip, id: saved.id).description)
        }
        await refreshKnowledgeMapContent()
        return refs.filter { knowledgeMap.nodesByRef[$0] != nil }
    }

    /// **Add to Canvas** on a passage in the Reader's notes: set down in the
    /// middle of the open canvas, which opens beside the reader if it is not
    /// showing.
    func addPassageToCanvas(_ highlight: SourceHighlight, in windowState: StudioWindowState) async {
        guard ReaderClip.isPassage(highlight) else { return }
        knowledgeMap.pendingPassageIDs.insert(highlight.id)
        await refreshKnowledgeMapContent()
        let ref = KnowledgeMap.ItemRef(kind: .clip, id: highlight.id).description
        guard knowledgeMap.nodesByRef[ref] != nil else {
            showToast("That passage's source is not on the canvas's shelf")
            return
        }
        if !knowledgeMapIsOnScreen { openCenterTabBeside(.knowledgeMap) }
        knowledgeMap.send(.dropAtCenter(refs: [ref], regionName: nil))
    }

    /// The learner's words on a clip: the mark's note, shown under its picture.
    func setKnowledgeMapClipNote(_ note: String, clipID: String) async {
        guard let clip = knowledgeMap.clips[clipID] else { return }
        await loadReaderHighlightsIfNeeded(for: clip.sourceID)
        await setReaderNoteComment(note, highlightID: clipID, sourceID: clip.sourceID)
        knowledgeMapClipRevision &+= 1
        await refreshKnowledgeMapContent()
    }

    /// Deletes a clip: off the Canvas, and gone from its source's notes.
    func deleteKnowledgeMapClip(_ clipID: String) async {
        guard let clip = knowledgeMap.clips[clipID] else { return }
        knowledgeMap.unplace([KnowledgeMap.ItemRef(kind: .clip, id: clipID).description])
        await loadReaderHighlightsIfNeeded(for: clip.sourceID)
        await removeReaderHighlight(highlightID: clipID, sourceID: clip.sourceID)
        knowledgeMapClipRevision &+= 1
        await refreshKnowledgeMapContent()
    }

    /// A clip's picture as the Canvas draws it: its page region, rendered from
    /// the PDF this Mac holds, the way the chat draws a figure it shows.
    func knowledgeMapClipPicture(_ clip: SourceHighlight) async -> String? {
        guard let reference = ReaderClip.reference(of: clip) else { return nil }
        let sourceID = clip.sourceID
        let token = SourceImageReference(sourceID: sourceID, location: reference.location, crop: reference.crop).urlString
        let image = await ChatSourceImage.resolved(
            token: token,
            articleForSourceID: { [weak self] id in await self?.persistedArticle(forLinkToken: id) }
        )
        return image.map { "data:\($0.mediaType);base64,\($0.data.base64EncodedString())" }
    }

    /// A clip's double-click: its paper opens beside the Canvas at the page,
    /// with the box outlined where it was cut.
    func openKnowledgeMapClip(_ clipID: String, in windowState: StudioWindowState) async {
        // A passage opens its paper at the words, as a highlight in the
        // Reader's notes does (Heptabase: a click on a highlight card goes
        // to where it came from).
        if let clip = knowledgeMap.clips[clipID], ReaderClip.isPassage(clip) {
            guard await openSourceBesideChat(clip.sourceID, beside: .knowledgeMap, in: windowState) else {
                showToast("That passage's source is not in the library")
                return
            }
            requestReaderPassage(clip.quote, page: ReaderClip.passagePage(of: clip) ?? knowledgeMap.passagePage(clip.id), for: clip.sourceID)
            return
        }
        guard let clip = knowledgeMap.clips[clipID], let reference = ReaderClip.reference(of: clip),
              case .page(let page) = reference.location else { return }
        guard await openSourceBesideChat(clip.sourceID, beside: .knowledgeMap, in: windowState) else {
            showToast("That clip's source is not in the library")
            return
        }
        focusWalkthrough(
            .figure(pageIndex: page - 1, rect: reference.crop, caption: ReaderClip.title(of: clip), sharesPageWithOtherFigures: false),
            stepID: "clip:\(clipID)",
            for: clip.sourceID
        )
    }
}

// MARK: - Pages of a PDF

/// What laying a PDF's pages out on the Canvas did.
struct KnowledgeMapPagesOutcome: Sendable {
    var sourceTitle: String
    var pageCount: Int
    /// The region the row is in; nil when every page asked for was on the
    /// canvas already.
    var regionID: String?
    /// The cards set down now, left to right.
    var refs: [String]
    /// Pages asked for that were on the canvas already, and so stayed.
    var alreadyOn: [Int]
    /// Pages asked for beyond the most one expansion sets down.
    var leftOut: Int
}

enum KnowledgeMapPagesError: LocalizedError {
    case unknownSource(String)
    case noPDF(String)
    case noSuchPages(String, Int)
    case noFigures(String)

    var errorDescription: String? {
        switch self {
        case .unknownSource(let id):
            return "No source in the library has the id \(id)."
        case .noPDF(let title):
            return "\(title) has no PDF on this Mac to lay out. Only a paper, or a book or hand-out kept as a PDF, has pages."
        case .noSuchPages(let title, let count):
            return "\(title) has \(count) \(count == 1 ? "page" : "pages"); none of the pages asked for is one of them."
        case .noFigures(let title):
            return "No figure of \(title) could be found: its PDF has no printed figure captions to read. Lay its pages out instead."
        }
    }
}

/// How a paper is laid out on a canvas: as its pages, or as its figures only
/// (docs/knowledge-map-design.md, "Figures only").
enum KnowledgeMapPaperLayout: String, CaseIterable, Sendable {
    case pages
    case figures
    case figuresExtended = "figures_extended"

    var includesExtended: Bool { self == .figuresExtended }

    var title: String {
        switch self {
        case .pages: return "Pages"
        case .figures: return "Figures"
        case .figuresExtended: return "Figures + Extended"
        }
    }
}

/// What **Lay Out Figures** did.
struct KnowledgeMapFiguresOutcome: Sendable {
    var sourceTitle: String
    /// Every figure the paper's index knows, main and extended.
    var figureCount: Int
    /// The extended and supplementary figures left out because only the main
    /// figures were asked for.
    var extendedLeftOut: Int
    var regionID: String?
    /// The cards set down now, left to right.
    var refs: [String]
    /// Figures that were on the canvas already, by their labels.
    var alreadyOn: [String]
}

@MainActor
extension StudioViewModel {
    /// The pages of a source's PDF on this Mac: how many there are, and each
    /// asked-for page's width over its height. Read off the main actor, as
    /// opening a PDF may pull it down from iCloud. Nil when the source has
    /// no PDF here.
    func knowledgeMapPDFShape(of article: StudioArticle, pages: [Int]?) async -> (pageCount: Int, aspects: [Int: Double])? {
        #if canImport(PDFKit)
        return await Task.detached(priority: .userInitiated) { () -> (Int, [Int: Double])? in
            // A book chapter is its pages of the book's file, numbered from its first.
            guard let document = article.pdfPages?.document(), document.pageCount > 0 else { return nil }
            var aspects: [Int: Double] = [:]
            for number in pages ?? Array(1...document.pageCount) where number >= 1 && number <= document.pageCount {
                // The media box, as the picture is drawn from it.
                guard let page = document.page(at: number - 1) else { continue }
                let box = page.bounds(for: .mediaBox)
                if box.width > 0, box.height > 0 { aspects[number] = Double(box.width / box.height) }
            }
            return (document.pageCount, aspects)
        }.value
        #else
        return nil
        #endif
    }

    /// Whether the source is one whose pages the Canvas can lay out: a
    /// source with a PDF this Mac already holds (a cached check, never an
    /// iCloud stat on the main actor).
    func knowledgeMapSourceHasPages(_ sourceID: String) -> Bool {
        articlesById[canonicalSourceID(sourceID)]?.resolvedPDFPath != nil
    }

    /// Whether a source placed on the Canvas for the first time shows its page:
    /// a paper whose PDF this Mac holds (product owner, 2026-10-10: a paper is
    /// a page).
    func knowledgeMapSourceShowsPage(_ sourceID: String) -> Bool {
        articlesById[canonicalSourceID(sourceID)]?.sourceType == .paper && knowledgeMapSourceHasPages(sourceID)
    }

    /// **Lay Out Pages**: one card for each of a PDF's pages, drawn from the
    /// PDF itself, set down left to right in a region named for the source
    /// (product owner, 2026-10-09: Heptabase's papers laid out page by page).
    /// `pages` is a range as `KnowledgeMap.pageRange` reads it ("2-5",
    /// "1,4,7-9"; all by default, at most `maximumPagesPerExpansion`).
    func layOutKnowledgeMapPages(sourceID: String, pages spec: String?, collapsed: Bool = false, color: String? = nil, near center: KnowledgeMapArranging.Spot? = nil) async throws -> KnowledgeMapPagesOutcome {
        let canonical = canonicalSourceID(sourceID)
        guard let article = articlesById[canonical] ?? articlesById[sourceID] else {
            throw KnowledgeMapPagesError.unknownSource(sourceID)
        }
        guard let shape = await knowledgeMapPDFShape(of: article, pages: nil) else {
            throw KnowledgeMapPagesError.noPDF(article.title)
        }
        guard let wanted = KnowledgeMap.pageRange(spec, pageCount: shape.pageCount) else {
            throw KnowledgeMapPagesError.noSuchPages(article.title, shape.pageCount)
        }
        let capped = Array(wanted.prefix(KnowledgeMap.maximumPagesPerExpansion))
        let map = knowledgeMap
        let alreadyOn = capped.filter { map.layout.placements[KnowledgeMap.pageRef(sourceID: article.id, page: $0)] != nil }
        let placed = map.layOutPages(
            sourceID: article.id,
            pages: capped,
            aspects: shape.aspects,
            regionName: article.title,
            near: center,
            color: color,
            collapsed: collapsed
        )
        // The page cards are read again from the layout now holding them.
        await refreshKnowledgeMapContent()
        return KnowledgeMapPagesOutcome(
            sourceTitle: article.title,
            pageCount: shape.pageCount,
            regionID: placed?.regionID,
            refs: placed?.refs ?? [],
            alreadyOn: alreadyOn,
            leftOut: wanted.count - capped.count
        )
    }

    /// **Lay Out Figures**: one card per figure of a paper, cut from its page
    /// as the Reader's Clip tool cuts one (a clip card: the picture, named by
    /// the figure's label, opening the page outlined), set down left to right
    /// in a region named for the paper (product owner, 2026-10-09: "a figure only
    /// mode"). The figures come from the paper's printed captions (the free
    /// half of the figure index) and the crop from the page's own ink; no
    /// model is called. The main figures first; the extended and
    /// supplementary ones too when `includeExtended`. A figure the page
    /// yields no crop for is the whole page. A figure cut this way before is
    /// the same clip again, not a second one.
    func layOutKnowledgeMapFigures(
        sourceID: String,
        includeExtended: Bool,
        collapsed: Bool = false,
        color: String? = nil,
        near center: KnowledgeMapArranging.Spot? = nil
    ) async throws -> KnowledgeMapFiguresOutcome {
        #if os(macOS)
        let canonical = canonicalSourceID(sourceID)
        guard let article = articlesById[canonical] ?? articlesById[sourceID] else {
            throw KnowledgeMapPagesError.unknownSource(sourceID)
        }
        guard article.sourceType == .paper, let shape = await knowledgeMapPDFShape(of: article, pages: nil) else {
            throw KnowledgeMapPagesError.noPDF(article.title)
        }
        let figures: [PaperFigureRecord]
        do {
            figures = try await paperFigureIndexer.prepareStructure(sourceID: article.id)
        } catch {
            throw KnowledgeMapPagesError.noFigures(article.title)
        }
        let chosen = PaperFigureSelection.ordered(figures, includeExtended: includeExtended, label: \.figureLabel, pageIndex: \.pageIndex)
        guard !chosen.isEmpty else { throw KnowledgeMapPagesError.noFigures(article.title) }
        let extendedLeftOut = includeExtended ? 0 : figures.filter { PaperFigureSelection.isExtended($0.figureLabel) }.count

        // Each figure's crop, read once per page from the caption anchor and the ink.
        let path = await Task.detached(priority: .userInitiated) { article.pdfPages?.cacheKey }.value
        let resolver = WalkthroughAnchorResolver(figures: figures, pdfPath: path)
        var regionsByPage: [Int: [ReaderClipFigureRegion]] = [:]
        await loadReaderHighlightsIfNeeded(for: article.id)
        let existing = readerHighlights[article.id] ?? []
        var transfers: [StudioClipTransfer] = []
        var labels: [String] = []
        for figure in chosen {
            if regionsByPage[figure.pageIndex] == nil {
                regionsByPage[figure.pageIndex] = await resolver.clipRegions(onPage: figure.pageIndex)
            }
            let crop = regionsByPage[figure.pageIndex]?
                .first { $0.figureLabel.lowercased() == figure.figureLabel.lowercased() }?.rect
                ?? PaperFigureRect(x: 0, y: 0, width: 1, height: 1)
            // The clip's pixel size only has to carry its shape: the card is
            // as tall as the crop is at the page's own proportions.
            let pageAspect = shape.aspects[figure.pageNumber] ?? (8.5 / 11)
            let pixelWidth = max(1, Int((crop.width * pageAspect * 1_000).rounded()))
            let pixelHeight = max(1, Int((crop.height * 1_000).rounded()))
            var transfer = StudioClipTransfer(
                sourceID: article.id, page: figure.pageNumber, crop: crop, title: figure.figureLabel,
                pixelWidth: pixelWidth, pixelHeight: pixelHeight, highlightID: nil
            )
            // The same figure cut before, by the Clip tool or by this, is reused.
            let reference = transfer.imageReference.urlString
            if let saved = existing.first(where: { ReaderClip.reference(of: $0)?.urlString == reference }) {
                transfer.highlightID = saved.id
            }
            transfers.append(transfer)
            labels.append(figure.figureLabel)
        }
        let refs = await knowledgeMapClipRefs(transfers)
        let map = knowledgeMap
        let alreadyOn = zip(refs, labels).filter { map.layout.placements[$0.0] != nil }.map(\.1)
        let placed = map.layOutRow(refs, regionName: article.title, near: center, color: color, collapsed: collapsed)
        await refreshKnowledgeMapContent()
        return KnowledgeMapFiguresOutcome(
            sourceTitle: article.title,
            figureCount: figures.count,
            extendedLeftOut: extendedLeftOut,
            regionID: placed?.regionID,
            refs: placed?.refs ?? [],
            alreadyOn: alreadyOn
        )
        #else
        throw KnowledgeMapPagesError.noFigures(sourceID)
        #endif
    }

    /// The paper a region lays out, and how, when every card in it is a page
    /// of one paper or a figure clip of one paper; nil for any other region.
    /// The region inspector's Pages / Figures switch reads it.
    func knowledgeMapPaperLayout(ofRegion id: String) -> (sourceID: String, layout: KnowledgeMapPaperLayout)? {
        let map = knowledgeMap
        let refs = map.refsInRegion(id)
        guard !refs.isEmpty else { return nil }
        var sources: Set<String> = []
        var pages = 0, figures = 0, extended = 0
        for ref in refs {
            guard let item = KnowledgeMap.ItemRef(ref) else { return nil }
            switch item.kind {
            case .page:
                guard let parts = item.pageParts else { return nil }
                sources.insert(parts.sourceID)
                pages += 1
            case .clip:
                guard let clip = map.clips[item.id], ReaderClip.isClip(clip) else { return nil }
                sources.insert(clip.sourceID)
                figures += 1
                if PaperFigureSelection.isExtended(ReaderClip.title(of: clip)) { extended += 1 }
            default:
                return nil
            }
        }
        guard sources.count == 1, let sourceID = sources.first, (pages == 0) != (figures == 0) else { return nil }
        if pages > 0 { return (sourceID, .pages) }
        return (sourceID, extended > 0 ? .figuresExtended : .figures)
    }

    /// Lays a paper's region out again another way: its cards leave the
    /// canvas, and the paper's pages or figures take their place in a region
    /// of the same name and colour, where the old one was. Two steps of Undo.
    func relayoutKnowledgeMapPaper(regionID: String, as layout: KnowledgeMapPaperLayout) async {
        let map = knowledgeMap
        guard let paper = knowledgeMapPaperLayout(ofRegion: regionID), paper.layout != layout,
              let region = map.layout.regions[regionID] else { return }
        let center = KnowledgeMapArranging.Spot(x: region.x + region.w / 2, y: region.y + region.h / 2)
        let color = region.color
        let collapsed = region.isCollapsed
        map.deleteRegion(regionID, takingCardsOff: true)
        do {
            let refs: [String]
            switch layout {
            case .pages:
                let outcome = try await layOutKnowledgeMapPages(sourceID: paper.sourceID, pages: nil, collapsed: collapsed, color: color, near: center)
                refs = outcome.refs
            case .figures, .figuresExtended:
                let outcome = try await layOutKnowledgeMapFigures(sourceID: paper.sourceID, includeExtended: layout.includesExtended, collapsed: collapsed, color: color, near: center)
                refs = outcome.refs
                if layout == .figures, outcome.extendedLeftOut > 0 {
                    showToast("\(outcome.extendedLeftOut) extended \(outcome.extendedLeftOut == 1 ? "figure" : "figures") left out; choose Figures + Extended to show them")
                }
            }
            if let first = refs.first { knowledgeMap.send(.focus(refs: [first], regionID: nil)) }
        } catch {
            showToast(error.localizedDescription)
        }
    }

    /// The width over height of each page card the canvas draws that has not
    /// been read yet (a canvas synced from another Mac, or a PDF replaced),
    /// so every card is as tall as its page. Reads each PDF once.
    func loadKnowledgeMapPageShapes() async {
        let map = knowledgeMap
        var wanted: [String: [Int]] = [:]
        for ref in map.pageRefs where map.pageAspects[ref] == nil {
            guard let parts = KnowledgeMap.ItemRef(ref)?.pageParts else { continue }
            wanted[parts.sourceID, default: []].append(parts.page)
        }
        for (sourceID, pages) in wanted {
            var aspects: [Int: Double] = [:]
            if let article = articlesById[sourceID], let shape = await knowledgeMapPDFShape(of: article, pages: pages) {
                aspects = shape.aspects
            }
            for page in pages {
                // 0 is "looked, found nothing", so a refresh does not look again.
                map.pageAspects[KnowledgeMap.pageRef(sourceID: sourceID, page: page)] = aspects[page] ?? 0
            }
        }
    }

    /// How many pages the PDF of each source the canvas may draw as its page
    /// has, and the first one's shape (`KnowledgeMapModel.pageFaces`): the
    /// sources placed with a `page`, and the papers a first placement would
    /// give one, so a paper set down shows its page at once. Each PDF is read
    /// once, off the main actor, eight at a time; one found to have no PDF is
    /// read again when this Mac comes to hold it.
    func loadKnowledgeMapPageFaces() async {
        let map = knowledgeMap
        var wanted: Set<String> = []
        for (ref, placement) in map.layout.placements where placement.page != nil {
            if let item = KnowledgeMap.ItemRef(ref), item.kind == .source { wanted.insert(item.id) }
        }
        for article in articles where article.status == .active && !article.isHidden && knowledgeMapSourceShowsPage(article.id) {
            wanted.insert(article.id)
        }
        let unread = wanted.filter { id in
            guard let face = map.pageFaces[id] else { return true }
            return face.pageCount == 0 && knowledgeMapSourceHasPages(id)
        }.sorted()
        var start = 0
        while start < unread.count {
            let batch = unread[start..<min(start + 8, unread.count)]
            start += batch.count
            let reads = batch.map { id -> (id: String, read: Task<(pageCount: Int, aspects: [Int: Double])?, Never>?) in
                guard let article = articlesById[id] ?? articlesById[canonicalSourceID(id)] else { return (id, nil) }
                return (id, Task { await self.knowledgeMapPDFShape(of: article, pages: [1]) })
            }
            for (id, read) in reads {
                let shape = await read?.value
                // 0 pages is "looked, found no PDF".
                map.pageFaces[id] = KnowledgeMapPageFace(pageCount: shape?.pageCount ?? 0, aspect: shape?.aspects[1])
            }
        }
    }

    /// A page card's picture: the page drawn from the PDF this Mac holds,
    /// as a data URL, smaller than the chat's picture of a page since a
    /// canvas may hold dozens of them.
    func knowledgeMapPagePicture(sourceID: String, page: Int) async -> String? {
        #if canImport(PDFKit)
        guard let article = articlesById[sourceID] ?? articlesById[canonicalSourceID(sourceID)] else { return nil }
        let rendered = await Task.detached(priority: .utility) { () -> SourceImageCatalog.RenderedImage? in
            guard let document = article.pdfPages?.document(),
                  page >= 1, page <= document.pageCount, let pdfPage = document.page(at: page - 1) else { return nil }
            return SourceImageCatalog.renderPage(pdfPage, crop: nil, maxPixelSize: 1100)
        }.value
        return rendered?.dataURL
        #else
        return nil
        #endif
    }

    /// A page card's double-click: the source opens beside the Canvas at that page.
    func openKnowledgeMapPage(sourceID: String, page: Int, in windowState: StudioWindowState) async {
        guard await openSourceBesideChat(articlesById[sourceID] != nil ? sourceID : canonicalSourceID(sourceID), beside: .knowledgeMap, in: windowState) else {
            showToast("That page's source is not in the library")
            return
        }
        requestReaderPassage(nil, page: page, for: sourceID)
    }
}
