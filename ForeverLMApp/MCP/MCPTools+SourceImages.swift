#if os(macOS)
import Foundation
import PDFKit

/// A picture a tool hands back beside its text.
///
/// Inside the app a chat shows a figure from a portable reference —
/// `foreverlm://image/<source>/page/<n>` — that every ForeverLM client renders
/// from its own copy of the PDF. A remote MCP client has no PDF, so the bytes
/// travel in the tool result as an MCP `image` content part, and the model on
/// the other end sees the actual figure rather than its caption.
struct MCPToolImage: Equatable, Sendable {
    let data: Data
    let mimeType: String
}

/// `inspect_paper_figure` and `show_source_image` over MCP: the in-app chat's
/// two picture tools, answered from the Mac's own PDFs and slide frames.
///
/// Before these, a model asked "can you show me Figure 3?" from Claude or
/// Codex had two routes and both were bad: `get_source_content` ends in a
/// caption list with no picture behind it, and the model then went looking
/// for the PDF on disk by hand — minutes of `find` and `grep` over the library
/// to end at a page it still could not see (2026-09-19). The Mac already held
/// the figure index, the vision analysis and the renderer; only the in-app
/// chat could reach them.
extension MCPDataStore {
    /// A tool result that may carry pictures. `text` follows the registry's
    /// convention: an error starts with `Error:`.
    struct MediaToolResult: Sendable {
        let text: String
        let images: [MCPToolImage]
        let isError: Bool

        static func failure(_ text: String) -> MediaToolResult {
            let prefixed = text.hasPrefix("Error:") ? text : "Error: \(text)"
            return MediaToolResult(text: prefixed, images: [], isError: true)
        }
    }

    /// How many pictures one result carries. A listing of a whole paper names
    /// every captioned figure; sending twelve rendered pages in one answer is
    /// megabytes the client did not ask for, so a long listing is text and the
    /// caller narrows it with `query` or `page` to get the pictures.
    static let maxImagesPerMediaResult = 4

    private enum LibrarySourceLookup {
        case found(StudioArticle)
        case notFound
        case excluded
    }

    /// Through the storage actor, never the cached connection: inspect_paper_figure
    /// is off the store gate (`storeGateExemptToolNames`) for its vision call.
    private func librarySource(forRequestedID requestedID: String) async throws -> LibrarySourceLookup {
        guard let resolvedID = try await notebookFileStorage.resolveSourceID(forLinkToken: requestedID) else {
            return .notFound
        }
        let excluded = try await notebookFileStorage.knowledgeSearchExcludedSourceIDs(includeArchived: true)
        guard !excluded.contains(resolvedID) else { return .excluded }
        guard let article = try await notebookFileStorage.loadPersistedSources(ids: [resolvedID]).first else {
            return .notFound
        }
        return .found(article)
    }

    private static let excludedSourceMessage =
        "Error: this source is excluded from knowledge search and AI in ForeverLM Settings › Sources. Include its source family there before showing its pictures."

    private static func requestedID(from arguments: [String: Any]) -> String? {
        let value = (arguments["source_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private static func integer(_ name: String, in arguments: [String: Any]) -> Int? {
        if let value = arguments[name] as? Int { return value }
        if let value = arguments[name] as? Double { return Int(value) }
        if let value = arguments[name] as? String { return Int(value.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// What every picture result says about the Markdown line it carries. The
    /// line is how a picture is placed in text that ForeverLM renders — a
    /// review transcript saved with `end_review_session`, a Doc — and it is
    /// meaningless anywhere else, where the attached image is the picture.
    private static let markdownLineGuidance =
        "The picture itself is attached to this result as an image. The Markdown image line "
        + "(foreverlm://image/…) renders the same picture inside ForeverLM: include it verbatim, on its own line, "
        + "in any text ForeverLM will show — a review transcript passed to end_review_session, a Doc — "
        + "and leave it out of an answer shown only here, where it would be a broken link."

    // MARK: inspect_paper_figure

    func inspectPaperFigure(arguments: [String: Any]) async -> MediaToolResult {
        guard let requestedID = Self.requestedID(from: arguments) else {
            return .failure("inspect_paper_figure needs a paper source_id, from list_sources or a search result.")
        }
        let requested = ((arguments["figure_label"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else {
            return .failure("inspect_paper_figure needs the printed figure label, for example Figure 2.")
        }
        let article: StudioArticle
        do {
            switch try await librarySource(forRequestedID: requestedID) {
            case .found(let found): article = found
            case .notFound: return .failure(ReviewSessionManager.sourceNotInLibraryMessage(requestedID))
            case .excluded: return .failure(Self.excludedSourceMessage)
            }
        } catch {
            return .failure(error.localizedDescription)
        }
        let sourceID = article.id

        let figures: [PaperFigureRecord]
        do {
            // The vision half — a model call for this one figure — runs only
            // when the figure has never been explained; a paper with an index
            // answers from it. The structural half is a read of the PDF.
            figures = try await paperFigureIndexer.prepare(sourceID: sourceID, figureLabel: requested)
        } catch {
            return .failure(error.localizedDescription)
        }
        guard let figure = PaperFigureIndexer.figure(labelled: requested, in: figures) else {
            return .failure(ReviewSessionManager.figureLabelNotFoundMessage(
                requested: requested,
                availableLabels: figures.map(\.figureLabel)
            ))
        }

        let requestedPanel = ((arguments["panel_label"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = []
        var crop: PaperFigureRect?
        var shownLabel = figure.figureLabel
        /// A panel asked for that no vision rectangle places: the page's own
        /// panel letters are tried before the whole figure is settled for.
        var panelToLocate: String?

        if let analysis = figure.analysis {
            let panel = ReviewSessionManager.paperFigurePanel(labelled: requestedPanel, in: analysis)
            if !requestedPanel.isEmpty, panel == nil {
                let labels = analysis.panels.map(\.label).joined(separator: ", ")
                let inventory = labels.isEmpty
                    ? "The vision analysis found no labelled panels in this figure."
                    : "Its labelled panels are: \(labels)."
                return .failure(
                    "\(figure.figureLabel) has no panel labelled \(requestedPanel). \(inventory) "
                        + "Call again without panel_label to show the whole figure, or with one of those labels."
                )
            }
            crop = ReviewSessionManager.paperFigureCrop(analysis: analysis, panel: panel)
            if let panel { shownLabel = PaperWalkthroughValidation.figurePanelLabel(figure.figureLabel, panel: panel.label) }
            lines = [
                "\(shownLabel) (PDF page \(figure.pageNumber))",
                "Caption: \(figure.caption)",
                "Explanation: \(panel?.explanation ?? analysis.summary)",
            ]
            if !analysis.visualEvidence.isEmpty {
                lines.append("Visible evidence: " + analysis.visualEvidence.joined(separator: "; "))
            }
            if !analysis.panels.isEmpty {
                lines.append("Panels: " + analysis.panels.map { "\($0.label): \($0.explanation)" }.joined(separator: " | "))
            }
            if let panel {
                if panel.rect?.isValid == true {
                    lines.append("The attached picture is cropped to panel \(panel.label) alone.")
                } else {
                    panelToLocate = panel.label
                }
            } else {
                let zoomable = analysis.panels.filter { $0.rect?.isValid == true }.map(\.label)
                if !zoomable.isEmpty {
                    lines.append(
                        "Each of these panels can be shown enlarged on its own: call inspect_paper_figure again with panel_label set to one of "
                            + zoomable.joined(separator: ", ") + "."
                    )
                }
            }
        } else {
            // No vision analysis — the vision model is not configured, or the
            // paper only ever had its captions indexed. The figure is still on
            // the page, and the caption says where it stops, so the picture is
            // cropped and shown; only the explanation is missing. The in-app
            // tool stops here and points at show_source_image; over MCP the
            // picture is the thing asked for, so it comes back.
            if !requestedPanel.isEmpty {
                panelToLocate = requestedPanel
            }
            lines.insert(contentsOf: [
                "\(figure.figureLabel) (PDF page \(figure.pageNumber))",
                "Caption: \(figure.caption)",
                "No vision explanation is available for this figure; read the attached picture directly.",
            ], at: 0)
        }

        var images: [MCPToolImage] = []
        if let path = article.resolvedLocalPath {
            if crop == nil || panelToLocate != nil {
                // The figure's crop off the page, and the panel's from the
                // page's own panel letters (`PaperFigurePanelLocator`) — the
                // same geometry the Reader's walkthrough outlines, so a model
                // asked about Figure 1C sees Figure 1C, not all of Figure 1.
                let structural = Self.structuralCrop(for: figure, in: figures, pdfPath: path, panel: panelToLocate)
                if let panelToLocate {
                    if let panelCrop = structural.panel {
                        crop = panelCrop
                        shownLabel = PaperWalkthroughValidation.figurePanelLabel(figure.figureLabel, panel: panelToLocate)
                        lines.append("The attached picture is cropped to panel \(panelToLocate) alone, placed from the panel letters printed in the figure.")
                    } else {
                        crop = crop ?? structural.figure
                        lines.append("Panel \(panelToLocate) could not be placed on the page (no vision rectangle, and the figure's text layer carries no panel letters), so the attached picture is the whole \(figure.figureLabel).")
                    }
                } else {
                    crop = structural.figure
                }
            }
            if let analysed = crop, panelToLocate == nil,
               let extended = Self.extendedAnalysedCrop(analysed, of: figure, pdfPath: path) {
                crop = extended
            }
            let reference = SourceImageReference(sourceID: sourceID, location: .page(figure.pageNumber), crop: crop)
            if let rendered = SourceImageCatalog.render(reference, filePath: path) {
                images.append(MCPToolImage(data: rendered.data, mimeType: rendered.mediaType))
            } else {
                lines.append("The PDF page could not be rendered on this Mac, so no picture is attached.")
            }
            lines.append("")
            lines.append("Markdown line: " + reference.markdown(alt: "\(shownLabel) (page \(figure.pageNumber))"))
            lines.append(Self.markdownLineGuidance)
        } else {
            lines.append("The paper's PDF is not on this Mac, so no picture is attached.")
        }
        return MediaToolResult(text: lines.joined(separator: "\n"), images: images, isError: false)
    }

    /// `crop` — the vision pass's rectangle for the figure or one of its
    /// panels — grown onto any ink its edges cut through, the way the
    /// Reader's outline is (`PaperFigureRectRefiner.extendedPanelRects`).
    /// Figure 2h of the cardiac-sodium paper was cut a group of bars short.
    static func extendedAnalysedCrop(
        _ crop: PaperFigureRect,
        of figure: PaperFigureRecord,
        pdfPath: String
    ) -> PaperFigureRect? {
        guard let analysis = figure.analysis, let figureRect = analysis.figureRect, figureRect.isValid,
              let document = PDFDocument(url: URL(fileURLWithPath: pdfPath)),
              let page = document.page(at: figure.pageIndex) else { return nil }
        return withExtendedLifetime(document) {
            guard let mask = PaperFigureRectRefiner.mask(for: page) else { return nil }
            var panels: [String: PaperFigureRect] = [:]
            for panel in analysis.panels {
                if let rect = panel.rect, rect.isValid { panels[panel.label] = rect }
            }
            let extended = PaperFigureRectRefiner.extendedPanelRects(panels, within: figureRect, with: mask)
            if crop == figureRect { return extended.figure }
            return panels.first { $0.value == crop }.flatMap { extended.panels[$0.key] }
        }
    }

    /// A figure's crop when the vision pass never measured one — the block of
    /// ink its printed caption belongs to, read off the page for free — and,
    /// when `panel` names one, that panel's, placed from the panel letters in
    /// the figure's text layer. Either is nil when the page will not yield it.
    static func structuralCrop(
        for figure: PaperFigureRecord,
        in figures: [PaperFigureRecord],
        pdfPath: String,
        panel: String? = nil
    ) -> (figure: PaperFigureRect?, panel: PaperFigureRect?) {
        guard let document = PDFDocument(url: URL(fileURLWithPath: pdfPath)),
              let page = document.page(at: figure.pageIndex) else { return (nil, nil) }
        // A PDFPage holds its document weakly, and PDFKit's text scanner
        // dereferences it: with the document released early (ARC may drop it
        // after its last use, at -O) `selectionForWord(at:)` crashes. Keep it
        // for as long as the page is read.
        return withExtendedLifetime(document) {
            let labelsOnPage = Set(figures.filter { $0.pageIndex == figure.pageIndex }.map(\.figureLabel)).count
            let mask = PaperFigureRectRefiner.mask(for: page)
            let figureCrop = figure.analysis?.figureRect.flatMap { $0.isValid ? $0 : nil }
                ?? PaperFigureRectRefiner.figureCrop(
                    forCaption: figure.caption,
                    on: page,
                    sharesPageWithOtherFigures: labelsOnPage > 1
                )
            guard let panel, let figureCrop else { return (figureCrop, nil) }
            return (figureCrop, PaperFigurePanelLocator.panelRect(labelled: panel, in: figureCrop, on: page, mask: mask))
        }
    }

    // MARK: show_source_image

    func showSourceImage(arguments: [String: Any]) async -> MediaToolResult {
        guard let requestedID = Self.requestedID(from: arguments) else {
            return .failure("show_source_image needs a source_id, from list_sources or a search result.")
        }
        let article: StudioArticle
        do {
            switch try await librarySource(forRequestedID: requestedID) {
            case .found(let found): article = found
            case .notFound: return .failure(ReviewSessionManager.sourceNotInLibraryMessage(requestedID))
            case .excluded: return .failure(Self.excludedSourceMessage)
            }
        } catch {
            return .failure(error.localizedDescription)
        }
        let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let page = Self.integer("page", in: arguments)
        let slide = Self.integer("slide", in: arguments)
        let crop = SourceImageReference.cropArgument(arguments["crop"])
        if arguments["crop"] != nil, crop == nil {
            return .failure("crop must be {x, y, width, height}, each a fraction between 0 and 1 of the picture from its top-left corner, staying inside it.")
        }

        // A video or recording has no file of pictures to walk; its pictures
        // are the slide frames captured from it, and any moment of it on request.
        if YouTubeTranscriptService.isYouTubeURL(article.url) || article.sourceType == .meeting {
            if arguments["at"] != nil {
                guard let seconds = SourceImageReference.timestampSeconds(arguments["at"]) else {
                    return .failure("at must be a time in the video — seconds (265) or a clock reading (4:25, 1:02:03).")
                }
                return await showVideoMoment(article: article, seconds: seconds, crop: crop)
            }
            return showVideoSlides(article: article, query: query, slide: slide, crop: crop)
        }
        if arguments["at"] != nil {
            return .failure("at is for videos and recordings; '\(article.title)' is not one. Use query or page.")
        }

        let sourceID = article.id
        // Indexing the captions when none are on file is free and is what
        // makes the crop possible at all; it explains nothing and spends nothing.
        var figures = (try? await notebookFileStorage.paperFigures(sourceID: sourceID)) ?? []
        if figures.isEmpty {
            figures = (try? await paperFigureIndexer.prepareStructure(sourceID: sourceID)) ?? []
        }
        guard let path = article.resolvedLocalPath else {
            return .failure(SourceImageCatalog.Failure.fileUnavailable.message)
        }
        let entries: [SourceImageEntry]
        do {
            let found = try SourceImageCatalog.entries(sourceID: sourceID, filePath: path, query: query, page: page)
            entries = ReviewSessionManager.croppedToFigures(
                found,
                sourceID: sourceID,
                filePath: path,
                figures: figures,
                query: query ?? ""
            )
        } catch let failure as SourceImageCatalog.Failure {
            return .failure(failure.message)
        } catch {
            return .failure(SourceImageCatalog.Failure.fileUnavailable.message)
        }

        var lines = ["Pictures in \"\(article.title)\" (\(entries.count) shown):"]
        for (index, entry) in entries.enumerated() {
            let name = entry.caption.isEmpty ? "Unnamed picture" : entry.caption
            lines.append("\(index + 1). \(name) — \(entry.locationDescription)")
            if entry.caption.isEmpty, !entry.context.isEmpty {
                lines.append("   Text that follows it: \(entry.context)")
            }
            lines.append("   \(entry.markdown)")
        }
        if (query ?? "").isEmpty, page == nil, entries.count == SourceImageCatalog.maxEntries {
            lines.append("Only the first \(SourceImageCatalog.maxEntries) are listed; pass query to find a specific figure.")
        }

        var images: [MCPToolImage] = []
        if entries.count <= Self.maxImagesPerMediaResult {
            for entry in entries {
                guard let rendered = SourceImageCatalog.render(entry.reference, filePath: path) else { continue }
                images.append(MCPToolImage(data: rendered.data, mimeType: rendered.mediaType))
            }
            lines.append("")
            lines.append(
                images.count == entries.count
                    ? "The \(images.count == 1 ? "picture is" : "\(images.count) pictures are") attached to this result as \(images.count == 1 ? "an image" : "images"), in the order listed."
                    : "\(images.count) of the \(entries.count) pictures could be rendered on this Mac and are attached as images, in the order listed."
            )
        } else {
            lines.append("")
            lines.append(
                "This is a listing: with more than \(Self.maxImagesPerMediaResult) pictures, none is attached. "
                    + "Call again with query set to a figure label or caption words, or page set to one of the pages above, to receive the picture itself."
            )
        }
        lines.append(Self.markdownLineGuidance)
        return MediaToolResult(text: lines.joined(separator: "\n"), images: images, isError: false)
    }

    /// The slide half of `show_source_image`. Over MCP nothing is captured
    /// here: a deck that was never captured is `extract_video_slides`' job, a
    /// named tool the model can announce and the learner can see running.
    /// `show_source_image` with `at`: the frame on screen at that moment,
    /// captured now from YouTube or the recording unless this Mac holds it,
    /// cropped when asked, and attached so the caller can look before it
    /// decides whether to crop in.
    private func showVideoMoment(article: StudioArticle, seconds: Int, crop: PaperFigureRect?) async -> MediaToolResult {
        let when = SlideFrameExtraction.displayTime(Double(seconds))
        do {
            try await ReviewSessionManager.ensureVideoMoment(article: article, seconds: seconds, storage: notebookFileStorage)
        } catch {
            return .failure("Couldn't capture the frame at \(when) of '\(article.title)': \(error.localizedDescription)")
        }
        let reference = SourceImageReference(sourceID: article.id, location: .moment(seconds), crop: crop)
        guard let rendered = SourceImageCatalog.renderMoment(reference) else {
            return .failure(
                crop == nil
                    ? "The frame at \(when) of '\(article.title)' was captured but could not be read back."
                    : "That crop leaves the frame at \(when). Give x, y, width and height as fractions between 0 and 1."
            )
        }
        let alt = "\(article.title) at \(when)" + (crop == nil ? "" : " (detail)")
        let lines = [
            "Frame at \(when) of \"\(article.title)\"\(crop == nil ? "" : ", cropped as asked"):",
            reference.markdown(alt: alt),
            "",
            "If only part of the frame matters — a diagram beside the speaker's camera, one panel of a slide — call show_source_image again with the same at and a crop of fractions from the top-left corner. If this is not the moment wanted, try a nearby time. To point at the moment itself, cite [\(article.title)](foreverlm://source/\(article.id)?t=\(seconds)).",
            Self.markdownLineGuidance,
        ]
        return MediaToolResult(
            text: lines.joined(separator: "\n"),
            images: [MCPToolImage(data: rendered.data, mimeType: rendered.mediaType)],
            isError: false
        )
    }

    private func showVideoSlides(article: StudioArticle, query: String?, slide: Int?, crop: PaperFigureRect?) -> MediaToolResult {
        let content: String
        do {
            guard let stored = try knowledgeStore().loadSourceContent(article.id), !stored.isEmpty else {
                return .failure("'\(article.title)' has no stored transcript yet, so there are no slides to show. Call fetch_video_transcript first.")
            }
            content = stored
        } catch {
            return .failure(error.localizedDescription)
        }
        guard SlideFrameExtraction.containsSlideSection(content) else {
            return .failure("'\(article.title)' has no slides captured yet. Call extract_video_slides with this source_id first; it captures the deck and lists the slides, and this tool shows them afterwards.")
        }
        var entries: [SourceImageEntry]
        do {
            entries = try SourceImageCatalog.slideEntries(sourceID: article.id, content: content, query: query, slide: slide)
            // A crop narrows one slide; over a listing it would be a guess
            // about every slide at once.
            if entries.count == 1, let crop, let entry = entries.first {
                entries = [SourceImageEntry(
                    reference: SourceImageReference(sourceID: entry.reference.sourceID, location: entry.reference.location, crop: crop),
                    caption: entry.caption,
                    context: entry.context
                )]
            }
        } catch let failure as SourceImageCatalog.Failure {
            return .failure(failure.message)
        } catch {
            return .failure(SourceImageCatalog.Failure.noImages.message)
        }
        var lines = ReviewSessionManager.slideListingLines(article: article, entries: entries, query: query, slide: slide)
        var images: [MCPToolImage] = []
        if entries.count <= Self.maxImagesPerMediaResult {
            for entry in entries {
                guard let rendered = SourceImageCatalog.renderSlide(entry.reference, content: content) else { continue }
                images.append(MCPToolImage(data: rendered.data, mimeType: rendered.mediaType))
            }
            lines.append(
                images.isEmpty
                    ? "The slide frames are not on this Mac, so no picture is attached."
                    : "\(images.count == 1 ? "The slide is" : "The \(images.count) slides are") attached to this result as \(images.count == 1 ? "an image" : "images"), in the order listed."
            )
        } else {
            lines.append(
                "This is a listing: with more than \(Self.maxImagesPerMediaResult) slides, none is attached. "
                    + "Call again with query set to words from the slide or what was said over it, or slide set to a number above, to receive the picture itself."
            )
        }
        lines.append(ReviewSessionManager.momentGuidance(sourceID: article.id))
        lines.append(Self.markdownLineGuidance)
        return MediaToolResult(text: lines.joined(separator: "\n"), images: images, isError: false)
    }
}
#endif
