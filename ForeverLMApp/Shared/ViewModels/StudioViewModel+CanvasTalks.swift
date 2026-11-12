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
    /// How many papers are recorded as cited on the talk's slides (dismissed
    /// ones left out). Zero when the slides were never read for citations,
    /// or cited nothing.
    var citedCount: Int
    /// Papers its slides cite that are not in the library (found and
    /// waiting, or not found).
    var citedElsewhere: Int
}

enum KnowledgeMapTalkError: LocalizedError {
    case unknownSource(String)
    case notATalk(String)
    case noSlides(String)
    case notShown(String)
    case busy(String)
    case canvasChanged

    var errorDescription: String? {
        switch self {
        case .unknownSource(let id): return "No source \(id) is in the library."
        case .notATalk(let title): return "\(title) is not a video or a recording, so it has no slides to lay out."
        case .noSlides(let title): return "No slides could be read from \(title)."
        case .notShown(let title): return "\(title) is hidden or archived, so its slides cannot go on a canvas."
        case .busy(let title): return "\(title) is being laid out already."
        case .canvasChanged: return "Another canvas was opened while the talk was being laid out, so nothing was set down."
        }
    }
}

/// The talks being laid out now, by source id, so a second click (or call)
/// makes no second set of slides.
@MainActor
private enum TalksBeingLaidOut {
    static var ids: Set<String> = []
}

/// Lay Out the Talk: a video's or a recording's slides as a storyboard on the
/// Canvas, with the papers each slide cites hung under it, one arrow from the
/// slide to each (docs/knowledge-map-design.md, "A talk's slides"). A slide is
/// a clip (`ReaderClip.slideHighlight`), drawn from the frame captured beside
/// the video, so it opens the video at its moment and takes a note like any
/// clip.
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
            guard isShown(canvas) else { return }
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
            if outcome.citedCount == 0 {
                // Reading the slides for citations is a vision call per slide: only on the learner's click.
                showToast(
                    "Laid out \(slides) of \(outcome.sourceTitle) · no cited papers are recorded for them",
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
        } catch KnowledgeMapTalkError.canvasChanged {
            // The learner moved on to another canvas; nothing to say on it.
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
        guard article.status == .active, !article.isHidden else { throw KnowledgeMapTalkError.notShown(article.title) }
        guard TalksBeingLaidOut.ids.insert(article.id).inserted else { throw KnowledgeMapTalkError.busy(article.title) }
        defer { TalksBeingLaidOut.ids.remove(article.id) }
        let canvas = knowledgeMap

        var content = await storage.loadSourceContent(article.id) ?? ""
        if !SlideFrameExtraction.containsSlideSection(content) {
            guard await extractSlideFrames(for: article.id) else { throw KnowledgeMapTalkError.noSlides(article.title) }
            content = await storage.loadSourceContent(article.id) ?? ""
        }
        let frames = YouTubeSlideContentParser.parse(content).displaySlides
        guard !frames.isEmpty else { throw KnowledgeMapTalkError.noSlides(article.title) }

        // Each slide's clip: the one saved before, else a new one. A slide
        // whose clip could not be saved is left out, with its papers.
        await loadReaderHighlightsIfNeeded(for: article.id)
        let existing = readerHighlights[article.id] ?? []
        var slideRefs: [(index: Int, ref: String)] = []
        var made = false
        for frame in frames {
            let reference = SourceImageReference(sourceID: article.id, location: .slide(frame.index)).urlString
            if let saved = existing.first(where: { ReaderClip.reference(of: $0)?.urlString == reference }) {
                slideRefs.append((frame.index, KnowledgeMap.ItemRef(kind: .clip, id: saved.id).description))
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
            slideRefs.append((frame.index, KnowledgeMap.ItemRef(kind: .clip, id: clip.id).description))
        }
        if made { knowledgeMapClipRevision &+= 1 }

        // The papers each slide cites that the library holds and shows: under
        // the slide each was read from (a paper that matches no slide shown
        // has nothing to hang under).
        let cited = await loadCitedPapers(forSourceID: article.id).filter { $0.status != .dismissed }
        var papersBySlide: [Int: [String]] = [:]
        var elsewhere = 0
        for (index, papers) in VideoCitedPaperWindow.bySlide(papers: cited, slides: frames) {
            for paper in papers {
                guard let id = librarySourceID(citedBy: paper) else {
                    elsewhere += 1
                    continue
                }
                let ref = KnowledgeMap.ItemRef(kind: .source, id: id).description
                if papersBySlide[index]?.contains(ref) != true { papersBySlide[index, default: []].append(ref) }
            }
        }

        await refreshKnowledgeMapContent(for: canvas)
        guard isShown(canvas) else { throw KnowledgeMapTalkError.canvasChanged }
        let talk = slideRefs.compactMap { slide -> (slide: String, papers: [String])? in
            canvas.nodesByRef[slide.ref] == nil ? nil : (slide.ref, papersBySlide[slide.index] ?? [])
        }
        guard !talk.isEmpty else { throw KnowledgeMapTalkError.noSlides(article.title) }
        let placed = canvas.layOutStoryboard(talk, regionName: article.title, near: center)
        let slides = placed?.slides ?? []
        return KnowledgeMapTalkOutcome(
            sourceTitle: article.title,
            regionID: placed?.regionID ?? nil,
            slides: slides.isEmpty ? talk.map(\.slide) : slides,
            papers: placed?.papers ?? [],
            changed: placed != nil,
            citedCount: cited.count,
            citedElsewhere: elsewhere
        )
    }

    /// The papers read off the slide a slide clip shows, as the transcript
    /// lists them under the slide; the dismissed ones left out. Empty for any
    /// other clip, and for a talk whose slides were never read for citations.
    func knowledgeMapSlideCitations(clipID: String) async -> [VideoCitedPaper] {
        guard let clip = knowledgeMap.clips[clipID], let slide = ReaderClip.slide(of: clip) else { return [] }
        let cited = await loadCitedPapers(forSourceID: clip.sourceID)
        guard cited.contains(where: { $0.status != .dismissed }) else { return [] }
        let content = await storage.loadSourceContent(clip.sourceID) ?? ""
        let frames = YouTubeSlideContentParser.parse(content).displaySlides
        return VideoCitedPaperWindow.bySlide(papers: cited, slides: frames)[slide] ?? []
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
        guard let sourceID else {
            showToast("Could not add \(paper.title)")
            return
        }
        await refreshKnowledgeMapContent(for: canvas)
        guard isShown(canvas) else { return }
        let paperRef = KnowledgeMap.ItemRef(kind: .source, id: sourceID).description
        // The talk's other slides on the canvas, in the order shown, so the
        // paper hangs in this slide's column above the next row of slides.
        let talkSlides = canvas.clips.values
            .filter { $0.sourceID == canvas.clips[clipID]?.sourceID && ReaderClip.slide(of: $0) != nil }
            .sorted { (ReaderClip.slide(of: $0) ?? 0) < (ReaderClip.slide(of: $1) ?? 0) }
            .map { KnowledgeMap.ItemRef(kind: .clip, id: $0.id).description }
            .filter { canvas.layout.placements[$0] != nil }
        let talk = talkSlides.map { ref in (slide: ref, papers: ref == slideRef ? [paperRef] : [String]()) }
        guard canvas.layOutStoryboard(talk.isEmpty ? [(slide: slideRef, papers: [paperRef])] : talk, regionName: "") != nil
                || canvas.layout.placements[paperRef] != nil else {
            showToast("\(paper.title) could not be set on this canvas")
            return
        }
        canvas.send(.focus(refs: [slideRef, paperRef], regionID: nil))
    }

    /// The library source a cited paper is, when the library holds it and
    /// shows it: the one it was imported as, else the one with its DOI or
    /// address (a talk in a field the learner reads cites papers they hold
    /// already, though never marked as imported).
    func librarySourceID(citedBy paper: VideoCitedPaper) -> String? {
        func shown(_ id: String) -> String? {
            guard let source = articlesById[canonicalSourceID(id)] ?? articlesById[id],
                  source.status == .active, !source.isHidden else { return nil }
            return source.id
        }
        if let imported = paper.importedSourceID, let id = shown(imported) { return id }
        if let doi = paper.doi?.trimmingCharacters(in: .whitespacesAndNewlines), !doi.isEmpty,
           let id = librarySourceID(forURL: "https://doi.org/\(Self.normalizeDOI(doi))").flatMap(shown) {
            return id
        }
        if let url = paper.url, !url.isEmpty, let id = librarySourceID(forURL: url).flatMap(shown) { return id }
        return nil
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
