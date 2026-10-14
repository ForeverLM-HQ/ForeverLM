import Foundation
import ImageIO

/// What laying a talk out on the Canvas did.
struct KnowledgeMapTalkOutcome: Sendable {
    var sourceTitle: String
    /// The region the storyboard is in; nil when every slide was on the
    /// canvas already.
    var regionID: String?
    /// The slides set down now, in the order they were shown; when every
    /// slide was on the canvas already, all of them.
    var slides: [String]
    /// The papers hung under their slides now (papers already on the canvas
    /// stay where they are, with an arrow from their slide).
    var papers: [String]
    /// Whether anything was set down or joined.
    var changed: Bool
    /// Papers the slides cite that are not in the library (found and
    /// waiting, or not found).
    var citedElsewhere: Int
    /// Whether the slides were ever read for the papers they cite.
    var citationsRead: Bool
}

enum KnowledgeMapTalkError: LocalizedError {
    case unknownSource(String)
    case notATalk(String)
    case noSlides(String)

    var errorDescription: String? {
        switch self {
        case .unknownSource(let id): return "No source \(id) is in the library."
        case .notATalk(let title): return "\(title) is not a video or a recording, so it has no slides to lay out."
        case .noSlides(let title): return "No slides could be read from \(title)."
        }
    }
}

/// Lay Out the Talk: a video's or a recording's slides as a storyboard on the
/// Canvas, with the papers each slide cites hung under it, one arrow from the
/// slide to each (docs/knowledge-map-design.md, "Clips"). A slide is a clip
/// (`ReaderClip.slideHighlight`), drawn from the frame captured beside the
/// video, so it opens the video at its moment and takes a note like any clip.
@MainActor
extension StudioViewModel {
    /// Whether **Lay Out the Talk** is offered for `sourceID`: a source frames
    /// can be read from.
    func canLayOutKnowledgeMapTalk(_ sourceID: String) -> Bool {
        guard let article = articlesById[canonicalSourceID(sourceID)] ?? articlesById[sourceID] else { return false }
        return Self.supportsSlideExtraction(article)
    }

    /// The menu's **Lay Out the Talk**: lays it out, focuses it and says what
    /// was set down, offering the papers the slides cite that are not in the
    /// library yet.
    func layOutKnowledgeMapTalkFromMenu(sourceID: String, in windowState: StudioWindowState) async {
        let canvas = knowledgeMap
        do {
            let outcome = try await layOutKnowledgeMapTalk(sourceID: sourceID)
            guard knowledgeMap === canvas else { return }
            guard outcome.regionID != nil else {
                // Laid out before: the papers new to the library hang under their slides.
                canvas.send(.focus(refs: outcome.papers.isEmpty ? outcome.slides : outcome.papers, regionID: nil), in: windowState.id)
                if outcome.papers.isEmpty {
                    showToast("\(outcome.sourceTitle) is laid out on this canvas already")
                } else {
                    showToast("Hung \(outcome.papers.count) more \(outcome.papers.count == 1 ? "paper" : "papers") under the slides of \(outcome.sourceTitle)")
                }
                return
            }
            canvas.send(.focus(refs: outcome.slides + outcome.papers, regionID: outcome.regionID), in: windowState.id)
            let slides = "\(outcome.slides.count) \(outcome.slides.count == 1 ? "slide" : "slides")"
            let papers = outcome.papers.isEmpty ? "" : " with \(outcome.papers.count) \(outcome.papers.count == 1 ? "paper" : "papers") they cite"
            let id = canonicalSourceID(sourceID)
            if !outcome.citationsRead {
                showToast(
                    "Laid out \(slides) of \(outcome.sourceTitle)",
                    action: StudioToastAction(title: "Find Cited Papers") { [weak self] _ in
                        await self?.extractPapersFromSlides(for: id)
                    }
                )
            } else if outcome.citedElsewhere > 0 {
                let elsewhere = "\(outcome.citedElsewhere) more \(outcome.citedElsewhere == 1 ? "isn't" : "aren't") in your library"
                showToast(
                    "Laid out \(slides)\(papers) · \(elsewhere)",
                    action: StudioToastAction(title: "Show Them") { [weak self] window in
                        guard let self, let window else { return }
                        _ = await self.openSourceBesideChat(id, beside: .knowledgeMap, in: window)
                    }
                )
            } else {
                showToast("Laid out \(slides)\(papers)")
            }
        } catch {
            showToast(error.localizedDescription)
        }
    }

    /// Lays a talk out on the open canvas: its slides (captured first if they
    /// never were) as clips in a storyboard, four to a row in the order they
    /// were shown, and each paper of the library a slide cites hung under it.
    /// A slide laid out before is the same clip again. One step of Undo.
    func layOutKnowledgeMapTalk(sourceID: String, near center: KnowledgeMapArranging.Spot? = nil) async throws -> KnowledgeMapTalkOutcome {
        let canonical = canonicalSourceID(sourceID)
        guard let article = articlesById[canonical] ?? articlesById[sourceID] else {
            throw KnowledgeMapTalkError.unknownSource(sourceID)
        }
        guard Self.supportsSlideExtraction(article) else { throw KnowledgeMapTalkError.notATalk(article.title) }
        let canvas = knowledgeMap

        var content = await storage.loadSourceContent(article.id) ?? ""
        if !SlideFrameExtraction.containsSlideSection(content) {
            guard await extractSlideFrames(for: article.id) else { throw KnowledgeMapTalkError.noSlides(article.title) }
            content = await storage.loadSourceContent(article.id) ?? ""
        }
        let frames = YouTubeSlideContentParser.parse(content).displaySlides
        guard !frames.isEmpty else { throw KnowledgeMapTalkError.noSlides(article.title) }

        // Each slide's clip: the one saved before, else a new one.
        await loadReaderHighlightsIfNeeded(for: article.id)
        let existing = readerHighlights[article.id] ?? []
        var slideRefs: [String] = []
        var made = false
        for frame in frames {
            let reference = SourceImageReference(sourceID: article.id, location: .slide(frame.index)).urlString
            if let saved = existing.first(where: { ReaderClip.reference(of: $0)?.urlString == reference }) {
                slideRefs.append(KnowledgeMap.ItemRef(kind: .clip, id: saved.id).description)
                continue
            }
            let size = await Self.slideFrameSize(frame.imagePath)
            let clip = ReaderClip.slideHighlight(
                sourceID: article.id, slide: frame.index, title: frame.displayTitle,
                pixelWidth: size.width, pixelHeight: size.height
            )
            applyLocally(clip)
            do {
                try await storage.saveSourceHighlight(clip)
            } catch {
                readerHighlights[article.id]?.removeAll { $0.id == clip.id }
                continue
            }
            made = true
            slideRefs.append(KnowledgeMap.ItemRef(kind: .clip, id: clip.id).description)
        }
        if made { knowledgeMapClipRevision &+= 1 }

        // The papers each slide cites that the library holds.
        let cited = await loadCitedPapers(forSourceID: article.id)
        var papersBySlide: [Int: [String]] = [:]
        var elsewhere = 0
        for paper in cited.sorted(by: { ($0.slideTimeSeconds ?? 0) < ($1.slideTimeSeconds ?? 0) }) where paper.status != .dismissed {
            guard let id = librarySourceID(citedBy: paper),
                  let source = articlesById[canonicalSourceID(id)] ?? articlesById[id],
                  source.status == .active, !source.isHidden else {
                elsewhere += 1
                continue
            }
            guard let slide = Self.slideIndex(citing: paper, among: frames) else { continue }
            let ref = KnowledgeMap.ItemRef(kind: .source, id: source.id).description
            if papersBySlide[slide]?.contains(ref) != true { papersBySlide[slide, default: []].append(ref) }
        }

        await refreshKnowledgeMapContent()
        guard knowledgeMap === canvas else { throw CancellationError() }
        let talk = zip(frames, slideRefs).compactMap { frame, ref -> (slide: String, papers: [String])? in
            canvas.nodesByRef[ref] == nil ? nil : (ref, papersBySlide[frame.index] ?? [])
        }
        let placed = canvas.layOutStoryboard(talk, regionName: article.title, near: center)
        let slides = placed?.slides ?? []
        return KnowledgeMapTalkOutcome(
            sourceTitle: article.title,
            regionID: placed?.regionID ?? nil,
            slides: slides.isEmpty ? talk.map(\.slide) : slides,
            papers: placed?.papers ?? [],
            changed: placed != nil,
            citedElsewhere: elsewhere,
            citationsRead: !cited.isEmpty
        )
    }

    /// The papers read off the slide a slide clip shows, in the order the
    /// slide's scan found them; the dismissed ones left out. Empty for any
    /// other clip, and for a talk whose slides were never read for citations.
    func knowledgeMapSlideCitations(clipID: String) async -> [VideoCitedPaper] {
        guard let clip = knowledgeMap.clips[clipID], let slide = ReaderClip.slide(of: clip) else { return [] }
        let cited = await loadCitedPapers(forSourceID: clip.sourceID).filter { $0.status != .dismissed }
        guard !cited.isEmpty else { return [] }
        let content = await storage.loadSourceContent(clip.sourceID) ?? ""
        let frames = YouTubeSlideContentParser.parse(content).displaySlides
        return cited.filter { Self.slideIndex(citing: $0, among: frames) == slide }
    }

    /// A paper cited on a slide, hung under the slide on the canvas with an
    /// arrow from it: the library's copy, else the paper added to the library
    /// first (`importCitedPaper`). One step of Undo for the canvas.
    func hangCitedPaper(_ paper: VideoCitedPaper, underSlideClip clipID: String) async {
        let canvas = knowledgeMap
        let slideRef = KnowledgeMap.ItemRef(kind: .clip, id: clipID).description
        guard canvas.layout.placements[slideRef] != nil else { return }
        var sourceID = librarySourceID(citedBy: paper)
        if sourceID == nil {
            guard paper.url?.isEmpty == false else {
                showToast("That paper was not found in any catalog, so it cannot be added")
                return
            }
            let updated = await importCitedPaper(paper)
            sourceID = updated.first { $0.id == paper.id }.flatMap { librarySourceID(citedBy: $0) }
        }
        guard let sourceID, let source = articlesById[canonicalSourceID(sourceID)] ?? articlesById[sourceID] else {
            showToast("Could not add \(paper.title)")
            return
        }
        await refreshKnowledgeMapContent()
        guard knowledgeMap === canvas else { return }
        let paperRef = KnowledgeMap.ItemRef(kind: .source, id: source.id).description
        _ = canvas.layOutStoryboard([(slide: slideRef, papers: [paperRef])], regionName: "")
        canvas.send(.focus(refs: [slideRef, paperRef], regionID: nil))
    }

    /// The library source a cited paper is: the one it was imported as, else
    /// the one with its DOI or address (a talk in a field the learner reads
    /// cites papers they hold already, though never marked as imported).
    func librarySourceID(citedBy paper: VideoCitedPaper) -> String? {
        if let imported = paper.importedSourceID, articlesById[canonicalSourceID(imported)] ?? articlesById[imported] != nil {
            return imported
        }
        if let doi = paper.doi.map(Self.normalizeDOI), !doi.isEmpty, let id = librarySourceID(forURL: "https://doi.org/\(doi)") {
            return id
        }
        if let url = paper.url, !url.isEmpty, let id = librarySourceID(forURL: url) { return id }
        return nil
    }

    /// The slide a cited paper was read from: the frame it names, else the
    /// slide on screen at its moment, else the last slide shown before it.
    nonisolated static func slideIndex(citing paper: VideoCitedPaper, among frames: [YouTubeSlideFrameContext]) -> Int? {
        if let path = paper.slideImagePath, let frame = frames.first(where: { $0.imagePath == path }) {
            return frame.index
        }
        guard let time = paper.slideTimeSeconds else { return frames.first?.index }
        if let frame = frames.first(where: { $0.windows.contains { $0.start <= time && time < ($0.end ?? .infinity) } }) {
            return frame.index
        }
        return frames.last { ($0.timeSeconds ?? 0) <= time }?.index ?? frames.first?.index
    }

    /// A captured frame's pixel size, which carries the slide card's shape;
    /// 16:9 when the frame cannot be read.
    nonisolated static func slideFrameSize(_ path: String) async -> (width: Int, height: Int) {
        await Task.detached(priority: .userInitiated) {
            let resolved = StorageService.locateSourceFile(path) ?? (path.hasPrefix("/") ? path : StorageService.absoluteSourcePath(path))
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: resolved) as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0 else { return (1280, 720) }
            return (width, height)
        }.value
    }
}
