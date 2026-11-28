// Part of ReviewSessionManager: figure, picture, slide and video tools.

import Foundation
import PDFKit

extension ReviewSessionManager {
    /// What `inspect_paper_figure` says when the label the learner asked for is
    /// not among the paper's indexed figures.
    ///
    /// Pure and static so a test can hold it to the one job it has: naming
    /// `show_source_image` as the next step. Both branches name it now.
    /// Listing the available labels and stopping there is what sent a request
    /// for a supplementary figure off to a web search, when the picture the
    /// learner ended up being shown was on page 2 of the attached PDF.
    nonisolated static func figureLabelNotFoundMessage(requested: String, availableLabels: [String]) -> String {
        let available = availableLabels.joined(separator: ", ")
        let inventory = available.isEmpty
            ? "This paper has no structurally labelled figures: its captions are not printed as \"Figure N\" lines."
            : "This paper's labelled figures are: \(available)."
        return "Error: \(requested) was not found. \(inventory) "
            + "A supplementary figure (Figure S-something) is printed in a separate file that this paper does not include, "
            + "and Extended Data figures missing from that list are missing from this copy of the PDF (a main-text-only file or an accepted manuscript), "
            + "and a graphical abstract or other unlabelled display item is never indexed by label even though it is in the PDF. "
            + "Do not search the web for it: call show_source_image with this source_id and query set to the caption words, "
            + "for example \"graphical abstract\", or page set to a PDF page. That shows the picture from this paper itself, "
            + "without a vision explanation."
    }

    /// The panel of `analysis` the learner asked for, or nil when nothing was
    /// asked for or the label matches no panel.
    ///
    /// The model spells a panel every way a paper does: "a", "A", "(a)", "1a",
    /// "Figure 1A", and a named panel "DESIGN" or "Design". The label is
    /// matched as it is written first, then by the panel's identity
    /// (`PaperWalkthroughValidation.panelKey`: the letter of a lettered
    /// panel, the whole name of a named one), and last by the final run of
    /// letters and digits, ignoring case.
    nonisolated static func paperFigurePanel(labelled requested: String, in analysis: PaperFigureAnalysis) -> PaperFigurePanel? {
        let wanted = Self.bareFigurePanelLabel(requested)
        guard !wanted.isEmpty else { return nil }
        if let exact = analysis.panels.first(where: { $0.label.caseInsensitiveCompare(requested) == .orderedSame }) {
            return exact
        }
        if let same = analysis.panels.first(where: { PaperWalkthroughValidation.samePanel($0.label, requested) }) {
            return same
        }
        return analysis.panels.first { Self.bareFigurePanelLabel($0.label).caseInsensitiveCompare(wanted) == .orderedSame }
    }

    /// The rectangle the transcript should crop the page to: the panel's own
    /// when one was asked for and the vision pass measured it, otherwise the
    /// figure's. A panel is never shown as the page.
    nonisolated static func paperFigureCrop(analysis: PaperFigureAnalysis, panel: PaperFigurePanel?) -> PaperFigureRect? {
        if let rect = panel?.rect, rect.isValid { return rect }
        return analysis.figureRect
    }

    /// Where `figureLabel` (and `panelLabel` within it) sits on its page, by
    /// the resolver the walkthrough and `focus_source_anchor` use; nil when
    /// the paper has no PDF on this Mac or the figure cannot be placed.
    private func paperFigureGeometry(
        sourceID: String,
        figures: [PaperFigureRecord],
        figureLabel: String,
        panelLabel: String?
    ) async -> WalkthroughResolvedAnchor? {
        let path: String?
        do {
            path = try await storage.paperFigureIndexTarget(sourceID: sourceID)?.pdfPath
        } catch {
            logger.error("Reading the figure index target failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard path != nil else { return nil }
        let resolver: WalkthroughAnchorResolver
        if let held = walkthroughResolver, walkthroughPlayback?.sourceID == sourceID,
           held.matches(figures: figures, pdfPath: path) {
            resolver = held
        } else {
            resolver = WalkthroughAnchorResolver(figures: figures, pdfPath: path)
        }
        return await resolver.resolve(PaperWalkthroughAnchor(figureLabel: figureLabel, panelLabel: panelLabel))
    }

    /// What `inspect_paper_figure` says when the chat's model reads text
    /// only and the figure's vision reading was not had — `failure` is the
    /// reading's error, nil when no model is set up to read figures. The
    /// learner still sees the figure under the step; the model, which could
    /// read neither the picture nor a reading of it, is told not to describe
    /// it. The caption is the paper's own text; nothing here stands in for
    /// the reading.
    nonisolated static func figureReadingUnavailableMessage(
        figureLabel: String,
        pageNumber: Int,
        caption: String,
        failure: String?
    ) -> String {
        let reason = failure.map { reason in
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            let closed = trimmed.last.map { ".!?".contains($0) } == true ? trimmed : trimmed + "."
            return "Error: the visual reading of \(figureLabel) failed: \(closed)"
        } ?? "Error: \(figureLabel) could not be read: no model is set up to read figures."
        return reason
            + " The chat's model reads text only, so the picture could not be handed to you either."
            + " The learner sees \(figureLabel) (PDF page \(pageNumber)) under this step in the chat."
            + " Tell them its reading failed, and do not describe what the figure shows as if you had seen it."
            + " Its printed caption, which is the paper's text rather than a reading of the picture: \(caption)"
    }

    /// What `inspect_paper_figure` says when the figure's page could not be
    /// drawn on this Mac (its PDF is not here, or will not render): the
    /// figure was not looked at, and the model must not talk as if it had.
    nonisolated static func figureNotDrawnMessage(figureLabel: String, pageNumber: Int, caption: String) -> String {
        "Error: \(figureLabel) is on PDF page \(pageNumber), but the page could not be drawn on this Mac, so the figure could not be looked at."
            + " Tell the learner, and do not describe what the figure shows as if you had seen it."
            + " Its printed caption, which is the paper's text rather than a reading of the picture: \(caption)"
    }

    /// What of `figure` is cut from its page for the chat, and what it is
    /// called: the panel asked for when one can be placed — the vision pass's
    /// rectangle, or the panel letters printed in the figure, by the resolver
    /// the walkthrough outlines with — otherwise the whole figure. `panel` is
    /// the vision pass's panel; `requestedPanel` is tried on the page's own
    /// letters when the pass named none. The page alone when nothing places
    /// the figure on it.
    private func figureCut(
        _ figure: PaperFigureRecord,
        in figures: [PaperFigureRecord],
        panel: PaperFigurePanel?,
        requestedPanel: String?,
        sourceID: String
    ) async -> (figure: ChatLookedAtFigure, panelPlaced: Bool) {
        let panelName = panel?.label ?? requestedPanel
        // The same geometry the walkthrough outlines: the analysed
        // rectangles, grown onto any ink their edges cut through.
        let resolved = await paperFigureGeometry(
            sourceID: sourceID,
            figures: figures,
            figureLabel: figure.figureLabel,
            panelLabel: panelName
        )
        var crop = figure.analysis.flatMap { Self.paperFigureCrop(analysis: $0, panel: panel) }
        // A panel nothing placed is shown as the whole figure, and the
        // figure is the page's crop, not the stored rectangle.
        if case .figure(_, let rect?, _, _) = resolved?.target, rect.isValid,
           panel == nil || resolved?.panel != nil || panel?.rect?.isValid != true {
            crop = rect
        }
        let panelPlaced = panelName != nil && (resolved?.panel != nil || panel?.rect?.isValid == true)
        let label = panelPlaced
            ? PaperWalkthroughValidation.figurePanelLabel(figure.figureLabel, panel: panelName)
            : figure.figureLabel
        let reference = SourceImageReference(sourceID: sourceID, location: .page(figure.pageNumber), crop: crop)
        return (ChatLookedAtFigure(reference: reference, label: label), panelPlaced)
    }

    /// Puts `figure` under the step `id` in the transcript, or takes it off
    /// when nil: the figure the step looked at, drawn small, as Codex shows
    /// what it is looking at.
    func showLookedAtFigure(_ figure: ChatLookedAtFigure?, onToolActivity id: UUID) {
        guard let index = chatMessages.firstIndex(where: { $0.id == id }),
              var activity = chatMessages[index].toolActivity,
              activity.lookedAtFigure != figure else { return }
        activity.lookedAtFigure = figure
        chatMessages[index].toolActivity = activity
    }

    /// The figure drawn from the paper's page, off the main actor, and held
    /// for the later turns that send it again. Nil when this Mac has no PDF
    /// of the paper or the page will not draw.
    func drawLookedAtFigure(_ figure: ChatLookedAtFigure, article: StudioArticle) async -> AttachedImage? {
        if let held = ChatLookedAtFigure.cached(figure.reference) { return held }
        let reference = figure.reference
        let rendered = await Task.detached(priority: .userInitiated) { () -> SourceImageCatalog.RenderedImage? in
            guard let path = article.resolvedFileLocation else { return nil }
            return SourceImageCatalog.render(reference, filePath: path)
        }.value
        guard let rendered else { return nil }
        let image = AttachedImage(data: rendered.data, mediaType: rendered.mediaType)
        ChatLookedAtFigure.stage(image, for: reference)
        return image
    }

    private nonisolated static func bareFigurePanelLabel(_ label: String) -> String {
        var trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "()[]."))
        // "Figure 1A", "Fig. 1a", "1a": the panel letter is the trailing run of
        // letters after the last digit. A bare "a" or "ii" has no digit and is
        // returned whole.
        if let lastDigit = trimmed.lastIndex(where: \.isNumber) {
            let tail = trimmed[trimmed.index(after: lastDigit)...]
            return String(tail).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let lastSpace = trimmed.lastIndex(of: " ") {
            return String(trimmed[trimmed.index(after: lastSpace)...])
        }
        return trimmed
    }

    /// `inspect_paper_figure`: the figure, or the panel asked for, cut from
    /// the paper's own page and handed to the model as a picture, the way a
    /// screenshot the learner attached would be (product owner, 2026-11-27:
    /// "it's really important that it always actually looks at the figure").
    /// Before then a second model's text reading of the figure stood in for
    /// the picture, and a chat asked about Fig. 1d described it from that
    /// reading without ever having seen it.
    ///
    /// The figure is drawn under the step in the chat, not outlined in the
    /// Reader (same day: "Instead of maybe highlighting with the blue
    /// rectangle, I think it makes more sense to have something similar to
    /// Codex"), and it stays with the chat (`ChatLookedAtFigure`). `showing`
    /// hands the step the figure as soon as its page places it, before the
    /// vision pass has measured its panels. `modelSeesPictures` is false for
    /// a chat model known to read text only, which gets the vision pass's
    /// reading instead, named as one.
    func inspectPaperFigure(
        arguments: [String: Any],
        modelSeesPictures: Bool = true,
        showing: (@MainActor (ChatLookedAtFigure) -> Void)? = nil
    ) async -> AppToolResult {
        guard let requestedID = (arguments["source_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !requestedID.isEmpty else {
            return AppToolResult(
                text: "Error: inspect_paper_figure needs a paper source_id, from the attached catalog or a search result.",
                isError: true
            )
        }
        guard let article = await librarySourceArticle(forRequestedID: requestedID) else {
            return AppToolResult(text: Self.sourceNotInLibraryMessage(requestedID), isError: true)
        }
        let sourceID = article.id
        let requested = ((arguments["figure_label"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else {
            return AppToolResult(
                text: "Error: inspect_paper_figure needs the printed figure label.",
                isError: true
            )
        }
        let requestedPanel = ((arguments["panel_label"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            // Preparing here is the point. Nothing else in a chat builds this
            // index — before this, the tool read a table that only a voice
            // review ever filled, so on any paper the learner had merely opened
            // it reported the index as "still being prepared" forever, and the
            // figure came back as an uncropped page. The structural half comes
            // first: the printed captions say which figures the paper has and
            // where each sits, with no model call.
            // An index built under older rules is read again here too: one
            // that predates Extended Data counting lists only the main figures,
            // and "Extended Data Figure 1" would be refused on a paper that
            // prints it.
            var figures = try await paperFigureIndexer.figuresForReading(sourceID: sourceID)
            // Show the figure before the vision pass. It takes seconds and can
            // fail — a rate-limited free model fails it — though where the
            // figure sits is known from its caption all along.
            if let indexed = PaperFigureIndexer.figure(labelled: requested, in: figures),
               indexed.analysis?.analysisVersion != PaperFigureAnalysis.currentVersion {
                let early = await figureCut(
                    indexed,
                    in: figures,
                    panel: nil,
                    requestedPanel: requestedPanel.isEmpty ? nil : requestedPanel,
                    sourceID: sourceID
                )
                showing?(early.figure)
            }
            // Then the vision half, which measures the panels: only the
            // requested figure, so the cost is one figure rather than the
            // paper. Its failure no longer costs the picture — the caption
            // index places the figure for free, and the chat's model reads the
            // picture itself — so it is logged, and a panel it would have
            // measured is placed from the figure's printed letters or shown
            // within the whole figure.
            var readingFailure: String?
            do {
                figures = try await paperFigureIndexer.prepare(
                    sourceID: sourceID,
                    figureLabel: requested
                )
            } catch {
                guard !(error is CancellationError),
                      PaperFigureIndexer.figure(labelled: requested, in: figures) != nil else { throw error }
                readingFailure = error.localizedDescription
                logger.warning("The vision reading of \(requested, privacy: .public) failed; the chat is shown the figure without it: \(error.localizedDescription, privacy: .public)")
            }
            guard let figure = PaperFigureIndexer.figure(labelled: requested, in: figures) else {
                // A miss here rarely means the picture does not exist. A
                // supplementary figure ("Figure S17") is printed in a separate
                // file the library does not hold, and an unlabelled display
                // item — a graphical abstract, a highlights panel — is right
                // there in this PDF but carries no "Figure N" line for the
                // index to catch. Both are still reachable through
                // show_source_image, so every branch says so. Naming it only
                // when the paper had no labels at all is what sent a Figure S17
                // miss to a web search for a figure sitting on page 2.
                return AppToolResult(
                    text: Self.figureLabelNotFoundMessage(
                        requested: requested,
                        availableLabels: figures.map(\.figureLabel)
                    ),
                    isError: true
                )
            }
            let analysis = figure.analysis
            let panel = analysis.flatMap { Self.paperFigurePanel(labelled: requestedPanel, in: $0) }
            if !requestedPanel.isEmpty, let analysis, panel == nil {
                let labels = analysis.panels.map(\.label).joined(separator: ", ")
                let inventory = labels.isEmpty
                    ? "The vision analysis found no labelled panels in this figure."
                    : "Its labelled panels are: \(labels)."
                return AppToolResult(
                    text: "Error: \(figure.figureLabel) has no panel labelled \(requestedPanel). \(inventory) "
                        + "Call again without panel_label to show the whole figure, or with one of those labels.",
                    isError: true
                )
            }
            let cut = await figureCut(
                figure,
                in: figures,
                panel: panel,
                requestedPanel: requestedPanel.isEmpty ? nil : requestedPanel,
                sourceID: sourceID
            )
            let looked = cut.figure
            guard let picture = await drawLookedAtFigure(looked, article: article) else {
                return AppToolResult(
                    text: Self.figureNotDrawnMessage(
                        figureLabel: looked.label,
                        pageNumber: figure.pageNumber,
                        caption: figure.caption
                    ),
                    isError: true
                )
            }
            showing?(looked)
            var lines = [
                "\(looked.label) of \u{201C}\(article.title)\u{201D} (PDF page \(figure.pageNumber))",
                "Caption: \(figure.caption)",
            ]
            let missedPanel = !requestedPanel.isEmpty && !cut.panelPlaced
            let zoomable = requestedPanel.isEmpty
                ? (analysis?.panels ?? []).filter { $0.rect?.isValid == true }.map(\.label)
                : []
            let enlarging = "Each of these panels can be shown enlarged on its own: call inspect_paper_figure again with panel_label set to one of "
                + zoomable.joined(separator: ", ") + "."
            let shownInChat = "The learner sees this picture under the step in the chat, and it stays with the chat for the turns that follow. Do not put an image line of it in the reply."
            if modelSeesPictures {
                lines.append(
                    "The picture of \(looked.label) is attached: it is the figure itself, cut from the paper's page. "
                        + "Look at it and answer from what it shows; where something in it cannot be made out, say so rather than guess. "
                        + "The caption is the paper's text, not a description of the picture."
                )
                if missedPanel {
                    lines.append("Panel \(requestedPanel) could not be cut out on its own, so the picture is the whole \(figure.figureLabel): find panel \(requestedPanel) in it by its printed letter.")
                }
                if !zoomable.isEmpty { lines.append(enlarging) }
                lines.append("")
                lines.append(shownInChat)
                return AppToolResult(
                    text: lines.joined(separator: "\n"),
                    isError: false,
                    images: [AIChatImage(data: picture.data, mediaType: picture.mediaType)],
                    lookedAtFigure: looked
                )
            }
            // A chat model that reads text only cannot be handed the picture;
            // the vision pass's reading is what it gets, named as a reading.
            guard let analysis else {
                return AppToolResult(
                    text: Self.figureReadingUnavailableMessage(
                        figureLabel: looked.label,
                        pageNumber: figure.pageNumber,
                        caption: figure.caption,
                        failure: readingFailure
                    ),
                    isError: true,
                    lookedAtFigure: looked
                )
            }
            lines.append("The chat's model reads text only, so the picture was not handed to you. What follows is a vision model's reading of it, not the paper's text.")
            lines.append("Reading: \(panel?.explanation ?? analysis.summary)")
            if !analysis.visualEvidence.isEmpty {
                lines.append("Visible evidence: " + analysis.visualEvidence.joined(separator: "; "))
            }
            if !analysis.panels.isEmpty {
                lines.append("Panels: " + analysis.panels.map { "\($0.label): \($0.explanation)" }.joined(separator: " | "))
            }
            if missedPanel {
                lines.append("Panel \(requestedPanel) could not be cut out on its own, so the learner sees the whole \(figure.figureLabel).")
            }
            if !zoomable.isEmpty { lines.append(enlarging) }
            lines.append("")
            lines.append(shownInChat)
            return AppToolResult(text: lines.joined(separator: "\n"), isError: false, lookedAtFigure: looked)
        } catch {
            return AppToolResult(text: "Error: \(error.localizedDescription)", isError: true)
        }
    }

    /// `show_source_image`: list or find the pictures in an attached source and
    /// hand back the portable Markdown lines that render them in the transcript.
    ///
    /// The file walk and any PDF work happen off the main actor; only the
    /// attached-source check and the paper-figure lookup run here.
    func showSourceImage(arguments: [String: Any]) async -> AppToolResult {
        guard let requestedID = (arguments["source_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !requestedID.isEmpty else {
            return AppToolResult(text: "Error: show_source_image needs a source_id, from the attached catalog or a search result.", isError: true)
        }
        guard let article = await librarySourceArticle(forRequestedID: requestedID) else {
            return AppToolResult(text: Self.sourceNotInLibraryMessage(requestedID), isError: true)
        }
        let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        func integer(_ name: String) -> Int? {
            if let value = arguments[name] as? Int { return value }
            if let value = arguments[name] as? Double { return Int(value) }
            if let value = arguments[name] as? String { return Int(value.trimmingCharacters(in: .whitespaces)) }
            return nil
        }
        let page = integer("page")
        let crop = SourceImageReference.cropArgument(arguments["crop"])
        if arguments["crop"] != nil, crop == nil {
            return AppToolResult(
                text: "Error: crop must be {x, y, width, height}, each a fraction between 0 and 1 of the picture from its top-left corner, staying inside it.",
                isError: true
            )
        }

        // A video or recording has no file of pictures to walk; its pictures are
        // the slide frames captured from it, and any moment of it on request.
        if StudioViewModel.supportsSlideExtraction(article) {
            if arguments["at"] != nil {
                guard let seconds = SourceImageReference.timestampSeconds(arguments["at"]) else {
                    return AppToolResult(
                        text: "Error: at must be a time in the video — seconds (265) or a clock reading (4:25, 1:02:03).",
                        isError: true
                    )
                }
                return await showVideoMoment(article: article, seconds: seconds, crop: crop)
            }
            return await showVideoSlides(article: article, query: query, slide: integer("slide"), crop: crop)
        }
        if arguments["at"] != nil {
            return AppToolResult(
                text: "Error: at is for videos and recordings; \"\(article.title)\" is not one. Use query or page.",
                isError: true
            )
        }

        let sourceID = article.id
        // Fetched before the detached work so the whole PDF pass — listing the
        // pictures and cropping them to their figures — happens once, off this
        // actor, with one open document.
        //
        // Indexing the captions when none are on file is free and is what makes
        // the crop possible at all; it explains nothing and spends nothing.
        // An index built under older rules is read again, so an Extended Data
        // figure the old rules skipped is still cropped to its figure.
        let figures: [PaperFigureRecord]
        do {
            figures = try await paperFigureIndexer.figuresForReading(sourceID: sourceID)
        } catch {
            logger.error("Reading the paper's figures failed: \(error.localizedDescription, privacy: .public)")
            figures = []
        }
        let listing = await Task.detached(priority: .userInitiated) { () -> Result<[SourceImageEntry], SourceImageCatalog.Failure> in
            guard let path = article.resolvedFileLocation else { return .failure(.fileUnavailable) }
            do {
                let found = try SourceImageCatalog.entries(
                    sourceID: sourceID,
                    filePath: path,
                    query: query,
                    page: page
                )
                return .success(Self.croppedToFigures(
                    found,
                    sourceID: sourceID,
                    filePath: path,
                    figures: figures,
                    query: query ?? ""
                ))
            } catch let failure as SourceImageCatalog.Failure {
                return .failure(failure)
            } catch {
                return .failure(.fileUnavailable)
            }
        }.value

        switch listing {
        case .failure(let failure):
            return AppToolResult(text: "Error: \(failure.message)", isError: true)
        case .success(let entries):
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
            lines.append("")
            lines.append("Include each Markdown image line verbatim, on its own line, where the picture belongs in your answer. The learner sees the original picture there and can copy or drag it out of the chat.")
            return AppToolResult(text: lines.joined(separator: "\n"), isError: false)
        }
    }

    /// The slide half of `show_source_image`. Slides are listed from the block
    /// the reader's "Show slides" capture writes into the stored content; a
    /// source whose slides were never captured is captured here first, by the
    /// same routes the reader button and `extract_video_slides` take.
    private func showVideoSlides(
        article: StudioArticle,
        query: String?,
        slide: Int?,
        crop: PaperFigureRect? = nil
    ) async -> AppToolResult {
        let content: String
        switch await capturedSlideContent(for: article) {
        case .failed(let failure):
            return failure
        case .ready(let readyContent, _, _):
            content = readyContent
        }
        switch await Self.slideListing(sourceID: article.id, content: content, query: query, slide: slide) {
        case .failure(let failure):
            return AppToolResult(text: "Error: \(failure.message)", isError: true)
        case .success(let found):
            // A crop narrows one slide to the part of the screen that matters;
            // over a listing it would be a guess about every slide at once.
            let entries = found.count == 1 && crop != nil
                ? found.map { entry in
                    SourceImageEntry(
                        reference: SourceImageReference(sourceID: entry.reference.sourceID, location: entry.reference.location, crop: crop),
                        caption: entry.caption,
                        context: entry.context
                    )
                }
                : found
            var lines = Self.slideListingLines(article: article, entries: entries, query: query, slide: slide)
            // The model sees the slides it is about to show, so it can tell
            // the learner what is on them and crop in on the part that matters.
            var images: [AIChatImage] = []
            if entries.count <= Self.maxPicturesPerToolResult {
                images = await Task.detached(priority: .userInitiated) {
                    entries.compactMap { entry in
                        SourceImageCatalog.renderSlide(entry.reference, content: content)
                            .map { AIChatImage(data: $0.data, mediaType: $0.mediaType) }
                    }
                }.value
                if !images.isEmpty {
                    lines.append("\(images.count == 1 ? "The slide is" : "The \(images.count) slides are") attached as \(images.count == 1 ? "an image" : "images"), in the order listed.")
                }
            }
            lines.append(Self.momentGuidance(sourceID: article.id))
            // A quiz deals these slides out one question at a time, so render
            // the rest now: each then appears with its question, not after it.
            ChatSourceImage.prewarmSlides(entries.map(\.reference), content: content)
            return AppToolResult(text: lines.joined(separator: "\n"), isError: false, images: images)
        }
    }

    /// Up to this many pictures ride along with one tool result, the ceiling
    /// the MCP route uses; a longer listing is text the model narrows first.
    static let maxPicturesPerToolResult = 4

    /// How to reach a moment no slide covers, and how to zoom in on one.
    nonisolated static func momentGuidance(sourceID: String) -> String {
        "To show any other moment of the video — an animation step, a diagram being drawn, what was on screen at a time the transcript names — call show_source_image with source_id \(sourceID) and at set to that time (seconds, or 4:25). To zoom in on part of a slide or frame, call it again with crop: {x, y, width, height} as fractions of the picture from its top-left corner, for example {\"x\": 0.55, \"y\": 0.15, \"width\": 0.45, \"height\": 0.75} for the right half below a title."
    }

    /// `show_source_image` with `at`: the frame on screen at that moment,
    /// captured from the video now — from YouTube's stream or the recording
    /// on disk — unless this Mac already holds it, and cropped when asked.
    private func showVideoMoment(article: StudioArticle, seconds: Int, crop: PaperFigureRect?) async -> AppToolResult {
        let sourceID = article.id
        let when = SlideFrameExtraction.displayTime(Double(seconds))
        do {
            try await Self.ensureVideoMoment(article: article, seconds: seconds, storage: storage)
        } catch {
            return AppToolResult(
                text: "Error: Couldn't capture the frame at \(when) of \"\(article.title)\": \(error.localizedDescription)",
                isError: true
            )
        }
        let reference = SourceImageReference(sourceID: sourceID, location: .moment(seconds), crop: crop)
        let rendered = await Task.detached(priority: .userInitiated) {
            SourceImageCatalog.renderMoment(reference)
        }.value
        guard let rendered else {
            return AppToolResult(
                text: crop == nil
                    ? "Error: The frame at \(when) of \"\(article.title)\" was captured but could not be read back."
                    : "Error: That crop leaves the frame at \(when). Give x, y, width and height as fractions between 0 and 1.",
                isError: true
            )
        }
        let alt = "\(article.title) at \(when)" + (crop == nil ? "" : " (detail)")
        let lines = [
            "Frame at \(when) of \"\(article.title)\"\(crop == nil ? "" : ", cropped as asked"), attached as an image:",
            reference.markdown(alt: alt),
            "",
            "Look at the picture before you show it. If only part of it matters — a diagram beside the speaker's camera, one panel of a slide — call show_source_image again with the same at and a crop, and show that line instead. If this is not the moment you wanted, try a nearby time.",
            "Include the Markdown image line verbatim, on its own line, where the picture belongs in your answer; the learner sees the frame there. To point at the moment itself, cite [\(article.title)](foreverlm://source/\(sourceID)?t=\(seconds)).",
        ]
        return AppToolResult(
            text: lines.joined(separator: "\n"),
            isError: false,
            images: [AIChatImage(data: rendered.data, mediaType: rendered.mediaType)]
        )
    }

    /// `extract_video_slides`: the reader's "Show slides" button, run from the
    /// chat. Captures the deck when the source has none and reports the one it
    /// has otherwise, and in both cases hands back the listing — so showing a
    /// slide afterwards is a matter of pasting a line, not of a second call.
    func extractVideoSlides(arguments: [String: Any]) async -> AppToolResult {
        guard let requestedID = (arguments["source_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !requestedID.isEmpty else {
            return AppToolResult(text: "Error: extract_video_slides needs an attached source_id.", isError: true)
        }
        guard let article = await attachedArticle(forRequestedID: requestedID) else {
            return AppToolResult(
                text: "Error: \(requestedID) is not an attached source. Use a source_id from the attached catalog.",
                isError: true
            )
        }
        guard StudioViewModel.supportsSlideExtraction(article) else {
            return AppToolResult(
                text: "Error: Slides can only be captured from YouTube videos and meeting recordings; \"\(article.title)\" is a \(article.sourceType.rawValue) source.",
                isError: true
            )
        }
        let content: String
        let summary: String
        switch await capturedSlideContent(for: article) {
        case .failed(let failure):
            return failure
        case .ready(let readyContent, let captured, let slideCount):
            content = readyContent
            let noun = slideCount == 1 ? "slide" : "slides"
            summary = captured
                ? "Captured \(slideCount) \(noun) from \"\(article.title)\"; the reader shows them beside the transcript now."
                : "\"\(article.title)\" already had \(slideCount) \(noun) captured; nothing was re-read."
        }
        switch await Self.slideListing(sourceID: article.id, content: content, query: nil, slide: nil) {
        case .failure(let failure):
            return AppToolResult(text: "\(summary) Error: \(failure.message)", isError: true)
        case .success(let entries):
            let lines = [summary, ""]
                + Self.slideListingLines(article: article, entries: entries, query: nil, slide: nil)
            return AppToolResult(text: lines.joined(separator: "\n"), isError: false)
        }
    }

    enum SlideCaptureOutcome {
        case ready(content: String, captured: Bool, slideCount: Int)
        case failed(AppToolResult)
    }

    /// The stored content of a video or recording with its slide block in
    /// place, capturing the deck first when there is none — by the routes the
    /// reader's "Show slides" button takes: YouTube's storyboards for a YouTube
    /// video, the recording file (through the Drive cache when it lives there)
    /// for a meeting. A capture is saved so the reader shows the deck too.
    private func capturedSlideContent(for article: StudioArticle) async -> SlideCaptureOutcome {
        let sourceID = article.id
        let content = await storage.loadSourceContent(sourceID) ?? article.content ?? ""
        if SlideFrameExtraction.containsSlideSection(content) {
            return .ready(
                content: content,
                captured: false,
                slideCount: YouTubeSlideContentParser.parse(content).displaySlides.count
            )
        }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed(AppToolResult(
                text: "Error: \"\(article.title)\" has no transcript yet, so its slides cannot be captured.",
                isError: true
            ))
        }
        let extraction: SlideFrameExtraction.AppendResult
        if YouTubeTranscriptService.isYouTubeURL(article.url) {
            extraction = await YouTubeSlideExtractionService.shared.appendingSlideContext(
                to: content,
                videoURL: article.url,
                sourceID: sourceID,
                videoTitle: article.title
            )
        } else if article.sourceType == .meeting {
            let mediaURL: URL
            do {
                mediaURL = try await meetingRecordingURL(for: sourceID)
            } catch {
                return .failed(AppToolResult(
                    text: "Error: Couldn't read the recording of \"\(article.title)\": \(error.localizedDescription)",
                    isError: true
                ))
            }
            extraction = await RecordingSlideExtractionService.shared.appendingSlideContext(
                to: content,
                mediaURL: mediaURL,
                sourceID: sourceID,
                videoTitle: article.title
            )
        } else {
            return .failed(AppToolResult(
                text: "Error: Slides can only be captured from YouTube videos and meeting recordings; \"\(article.title)\" is neither.",
                isError: true
            ))
        }
        if let message = extraction.errorMessage {
            return .failed(AppToolResult(
                text: "Error: Couldn't capture the slides of \"\(article.title)\": \(message)",
                isError: true
            ))
        }
        guard extraction.slideCount > 0 else {
            return .failed(AppToolResult(
                text: "Error: No slides could be found in the frames of \"\(article.title)\".",
                isError: true
            ))
        }
        var updated = article
        updated.content = extraction.content
        updated.wordCount = extraction.content.split(separator: " ").count
        do {
            try await storage.saveSource(updated)
        } catch {
            return .failed(AppToolResult(
                text: "Error: The slides were captured but could not be saved: \(error.localizedDescription)",
                isError: true
            ))
        }
        if let index = activeArticles.firstIndex(where: { $0.id == sourceID }) {
            activeArticles[index] = updated
        }
        NotificationCenter.default.post(name: .foreverLMDataDidChange, object: nil)
        return .ready(content: extraction.content, captured: true, slideCount: extraction.slideCount)
    }

    /// Makes sure this Mac holds the frame at `seconds` of a video or
    /// recording, capturing it when it does not: from YouTube's stream, or
    /// from the meeting's recording. Shared by the chat and MCP routes of
    /// `show_source_image`.
    nonisolated static func ensureVideoMoment(article: StudioArticle, seconds: Int, storage: StorageService) async throws {
        let sourceID = article.id
        let alreadyCaptured = await Task.detached(priority: .userInitiated) {
            SlideFrameExtraction.existingMomentFramePath(sourceID: sourceID, seconds: seconds) != nil
        }.value
        guard !alreadyCaptured else { return }
        if YouTubeTranscriptService.isYouTubeURL(article.url) {
            _ = try await YouTubeSlideExtractionService.shared.captureMoment(
                videoURL: article.url,
                sourceID: sourceID,
                seconds: seconds
            )
        } else if article.sourceType == .meeting {
            let mediaURL = try await meetingRecordingURL(for: sourceID, storage: storage)
            _ = try await RecordingSlideExtractionService.shared.captureMoment(
                mediaURL: mediaURL,
                sourceID: sourceID,
                seconds: seconds
            )
        } else {
            throw SlideExtractionError.unreadableRecording
        }
    }

    private func meetingRecordingURL(for sourceID: String) async throws -> URL {
        try await Self.meetingRecordingURL(for: sourceID, storage: storage)
    }

    /// Where a meeting's recording is, found the way the reader finds it: the
    /// artifact's local file when it has one, otherwise its Drive copy through
    /// the recording cache (a download on first use).
    nonisolated static func meetingRecordingURL(for sourceID: String, storage: StorageService) async throws -> URL {
        let artifacts = try await storage.loadMeetingArtifacts(sourceID: sourceID)
        guard let recording = artifacts.first(where: { $0.kind == .recording }) else {
            throw MeetingTranscriptError.noRecording
        }
        if let localPath = recording.localFilePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !localPath.isEmpty {
            let resolvedPath = await Task.detached(priority: .utility) {
                StorageService.locateSourceFile(localPath) ?? StorageService.absoluteSourcePath(localPath)
            }.value
            return URL(fileURLWithPath: resolvedPath)
        }
        if let remote = recording.url?.trimmingCharacters(in: .whitespacesAndNewlines), !remote.isEmpty {
            return try await GoogleDriveService.shared.cachedRecordingURL(
                fileURLOrID: remote,
                mimeType: recording.mimeType,
                modifiedAt: recording.modifiedAt
            )
        }
        throw MeetingTranscriptError.noRecording
    }

    /// The deck's entries, listed off the main actor: parsing the block and
    /// matching the spoken words is string work over the whole transcript.
    private static func slideListing(
        sourceID: String,
        content: String,
        query: String?,
        slide: Int?
    ) async -> Result<[SourceImageEntry], SourceImageCatalog.Failure> {
        await Task.detached(priority: .userInitiated) { () -> Result<[SourceImageEntry], SourceImageCatalog.Failure> in
            do {
                return .success(try SourceImageCatalog.slideEntries(
                    sourceID: sourceID,
                    content: content,
                    query: query,
                    slide: slide
                ))
            } catch let failure as SourceImageCatalog.Failure {
                return .failure(failure)
            } catch {
                return .failure(.noImages)
            }
        }.value
    }

    /// The slide listing as the model reads it: one numbered entry per slide
    /// with its on-screen window, the words spoken over it, and the Markdown
    /// line that shows it, then the instruction to paste those lines verbatim.
    nonisolated static func slideListingLines(
        article: StudioArticle,
        entries: [SourceImageEntry],
        query: String?,
        slide: Int?
    ) -> [String] {
        var lines = ["Slides in \"\(article.title)\" (\(entries.count) shown):"]
        for (index, entry) in entries.enumerated() {
            lines.append("\(index + 1). \(entry.caption)")
            if !entry.context.isEmpty {
                lines.append("   Spoken while on screen: \(SourceImageEntry.shortened(entry.context, limit: 220))")
            }
            lines.append("   \(entry.markdown)")
        }
        if (query ?? "").isEmpty, slide == nil, entries.count == SourceImageCatalog.maxEntries {
            lines.append("Only the first \(SourceImageCatalog.maxEntries) are listed; pass query with words from the slide or what was said over it, or slide with a number.")
        }
        lines.append("")
        lines.append("Include each Markdown image line verbatim, on its own line, where the picture belongs in your answer. The learner sees the slide there and can copy or drag it out of the chat. In a review or quiz, show one slide per question: the slide the question you are asking is about, directly above it. These lines stay valid for the rest of the chat, so a slide listed here can be shown in a later reply without calling show_source_image again. To point at the moment the slide is on screen, cite the source with that moment's start in seconds: [Title](foreverlm://source/\(article.id)?t=SECONDS).")
        return lines
    }

    /// `generate_image`: draws a picture with the account's image model, keeps
    /// the bytes in this device's store, and hands back the portable line that
    /// shows it. The model is the Settings choice, never named here.
    func generateChatImage(arguments: [String: Any]) async -> AppToolResult {
        guard let prompt = Self.nonEmptyTrimmed(arguments["prompt"] as? String) else {
            return AppToolResult(text: "Error: generate_image needs a prompt describing the picture.", isError: true)
        }
        let shape = Self.enumArgument(arguments["shape"], ImageGenerationCatalog.Shape.init(rawValue:)) ?? .square
        let quality = Self.enumArgument(arguments["quality"], ImageGenerationCatalog.Quality.init(rawValue:)) ?? .medium
        let revising = Self.imageID(fromArgument: arguments["revises"])
        let title = GeneratedImageStore.cleanTitle(arguments["title"] as? String)
        // Refused before anything is drawn, so a missing title costs nothing.
        guard title != nil || revising != nil else {
            return AppToolResult(text: "Error: generate_image needs a title for a new picture: two to six words naming it, as a file is named.", isError: true)
        }
        let model = MacImageGenerationSettings.model
        do {
            // A picture drawn in a Notebook's chat lives in its notebook, when
            // the notebook takes new things (`madeThingFiling`).
            let stored = try await ManagedImageGeneration.drawAndStore(
                prompt: prompt,
                title: title,
                model: model,
                shape: shape,
                quality: quality,
                revising: revising,
                usageTask: "chat_image",
                notebookID: madeThingNotebookID
            )
            guard let reference = stored.reference else {
                throw ManagedImageGeneration.Failure.noImageReturned
            }
            let line = reference.markdown(alt: stored.details?.title ?? Self.generatedImageAlt(prompt))
            let what = stored.version > 1
                ? "Drew version \(stored.version) of the picture with \(model.name); it replaces the earlier one, and the image keeps every version."
                : "Drew a \(shape.rawValue) picture with \(model.name)."
            return AppToolResult(
                text: """
                \(what)
                \(line)

                Include the Markdown image line above verbatim, on its own line, where the picture belongs in your answer. The learner sees the picture there and can copy or drag it out of the chat. Do not repeat the prompt back; one short sentence about the picture is enough. To change this picture later, call generate_image again with revises: "\(stored.id)".
                """,
                isError: false
            )
        } catch {
            return AppToolResult(text: "Error: \(error.localizedDescription)", isError: true)
        }
    }

    /// The image a `revises` argument names: a bare id, or the picture's
    /// `foreverlm://image/generated/<id>` line or address.
    nonisolated static func imageID(fromArgument raw: Any?) -> String? {
        guard var text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if let open = text.range(of: "("), let close = text.range(of: ")", range: open.upperBound..<text.endIndex) {
            text = String(text[open.upperBound..<close.lowerBound])
        }
        return GeneratedImageReference(urlString: text)?.id ?? GeneratedImageReference(id: text)?.id ?? text
    }

    /// `list_generated_images`: the images this Mac holds — each once, at
    /// its latest version — with the line that shows it again.
    func listGeneratedImages(arguments: [String: Any]) async -> AppToolResult {
        let query = Self.nonEmptyTrimmed(arguments["query"] as? String)
        let limit = min(max((arguments["limit"] as? Int) ?? 20, 1), 100)
        let loaded = await Task.detached(priority: .userInitiated) {
            GeneratedImageStore.imageGroups()
        }.value
        // Screen record mode (admin only): the pictures the take may show, so
        // a filmed chat cannot list the rest.
        let scope = ScreenRecordScope.resolve { _ in [] }
        let groups = scope.map { scope in
            loaded.filter { scope.allowsImage(id: $0.imageID, createdAt: $0.updatedAt) }
        } ?? loaded
        let catalog = GeneratedImageStore.catalog(groups, query: query, limit: limit, forMCP: false)
        return AppToolResult(
            text: catalog + "\n\nTo show one again, include its Markdown image line verbatim, on its own line, where the picture belongs in your answer. To change one, call generate_image with revises set to the id in its line: the new picture becomes its next version rather than a new image.",
            isError: false
        )
    }

    private static func enumArgument<Value>(_ raw: Any?, _ make: (String) -> Value?) -> Value? {
        guard let text = nonEmptyTrimmed(raw as? String) else { return nil }
        return make(text.lowercased())
    }

    /// Alt text for a drawn picture: the opening of its prompt, capped so a
    /// paragraph-long description does not become the caption.
    nonisolated static func generatedImageAlt(_ prompt: String) -> String {
        GeneratedImageStore.altText(prompt)
    }

    /// Resolves a tool's `source_id` against the attached pool, accepting the
    /// unambiguous prefixes models sometimes shorten IDs to.
    private func attachedArticle(forRequestedID requestedID: String) async -> StudioArticle? {
        let attachedID: String?
        if activeSourceIDs.contains(requestedID) {
            attachedID = requestedID
        } else if requestedID.count >= 8 {
            let matches = activeSourceIDs.filter { $0.hasPrefix(requestedID) }
            attachedID = matches.count == 1 ? matches.first : nil
        } else {
            attachedID = nil
        }
        guard let attachedID else { return nil }
        if let loaded = activeArticles.first(where: { $0.id == attachedID }) { return loaded }
        return await loadLibrarySource(id: attachedID)
    }

    /// The source a picture tool was asked about: an attached one first, by
    /// the same prefix-tolerant match, then any source the library holds under
    /// that full ID.
    ///
    /// The picture tools read a source's file and nothing else, so nothing
    /// about them needs the source's text in this chat's context. Requiring
    /// it would mean a paper that a search had just found could not have its figure
    /// shown until the learner attached it by hand — and the model, told the
    /// ID was "not attached", would open the publisher's page in the browser for
    /// a figure sitting in the library's own PDF.
    func librarySourceArticle(forRequestedID requestedID: String) async -> StudioArticle? {
        if let attached = await attachedArticle(forRequestedID: requestedID) { return attached }
        return await loadLibrarySource(id: requestedID)
    }

    private func loadLibrarySource(id: String) async -> StudioArticle? {
        do {
            return try await storage.loadPersistedSources(ids: [id]).first
        } catch {
            logger.error("Reading a source for a picture tool failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// What the picture tools say about an ID that names nothing in the
    /// library. Static so a test can hold it to naming the route that works.
    nonisolated static func sourceNotInLibraryMessage(_ requestedID: String) -> String {
        "Error: \(requestedID) is not a source in this library. Use a source_id from the attached catalog "
            + "or from a search_sources_semantic result; a library source need not be attached to this chat."
    }

    /// Narrow a page reference to the figure printed on it.
    ///
    /// Two sources of geometry, in order. A figure whose vision pass has run
    /// carries a stored rectangle, already snapped to the page's ink when it was
    /// written. A figure that has only been *indexed* — which is free, and is
    /// what a paper gets just by being asked about — carries only its caption,
    /// and that is enough: `PaperFigureRectRefiner` finds the caption on the
    /// page and takes the block of ink it belongs to. So a figure is cropped
    /// whether or not anyone has paid to have it explained.
    ///
    /// Nonisolated and given its own file path: this rasterizes pages, and the
    /// caller runs it inside the detached task that already opened the document.
    /// Internal rather than private so a test can drive the same selection the
    /// tool drives, on a real paper.
    nonisolated static func croppedToFigures(
        _ entries: [SourceImageEntry],
        sourceID: String,
        filePath: String,
        figures: [PaperFigureRecord],
        query: String
    ) -> [SourceImageEntry] {
        guard !figures.isEmpty,
              entries.contains(where: { if case .page = $0.reference.location { true } else { false } })
        else { return entries }
        #if os(macOS)
        guard let document = SourcePDFPages(stored: filePath).document() else { return entries }
        let labelsPerPage = Dictionary(grouping: figures, by: \.pageIndex)
            .mapValues { Set($0.map(\.figureLabel)).count }

        // When the query names a figure this paper actually has, the answer is
        // that figure — not every page whose text happens to contain the words.
        // A PDF query search matches page *text*, so asking for "Figure 3" on a
        // paper that discusses Figure 3 in its prose returns the discussion
        // pages too, ordered by page number, and the figure itself lands
        // somewhere down the list behind them. The model then pastes the first
        // thing it was handed, which is a page of paragraphs.
        if !query.isEmpty {
            var seen = Set<String>()
            let named = figures
                .filter {
                    SourceImageCatalog.textMatches($0.figureLabel, query: query)
                        || SourceImageCatalog.textMatches($0.caption, query: query)
                }
                .sorted { $0.pageIndex < $1.pageIndex }
                // A caption continued onto the next page repeats the label; the
                // figure is on the first of them.
                .filter { seen.insert($0.figureLabel.lowercased()).inserted }
            if !named.isEmpty {
                return named.compactMap { figure in
                    guard let page = document.page(at: figure.pageIndex) else { return nil }
                    return SourceImageEntry(
                        reference: SourceImageReference(
                            sourceID: sourceID,
                            location: .page(figure.pageNumber),
                            crop: cropFor(figure, page: page, labelsPerPage: labelsPerPage)
                        ),
                        caption: figure.caption,
                        context: ""
                    )
                }
            }
        }

        return entries.map { entry in
            guard case .page(let page) = entry.reference.location, entry.reference.crop == nil else {
                return entry
            }
            let onPage = figures.filter { $0.pageIndex == page - 1 }
            let chosen: PaperFigureRecord?
            if !query.isEmpty {
                chosen = onPage.first {
                    SourceImageCatalog.textMatches($0.figureLabel, query: query)
                        || SourceImageCatalog.textMatches($0.caption, query: query)
                }
            } else if !entry.caption.isEmpty {
                chosen = onPage.first { SourceImageCatalog.textMatches(entry.caption, query: $0.figureLabel) }
            } else {
                chosen = onPage.count == 1 ? onPage.first : nil
            }
            guard let chosen else { return entry }

            guard let pdfPage = document.page(at: chosen.pageIndex),
                  let crop = cropFor(chosen, page: pdfPage, labelsPerPage: labelsPerPage)
            else { return entry }
            return SourceImageEntry(
                reference: SourceImageReference(sourceID: sourceID, location: .page(page), crop: crop),
                caption: entry.caption.isEmpty ? chosen.caption : entry.caption,
                context: entry.context
            )
        }
        #else
        return entries
        #endif
    }

    /// A figure's crop: the one the page itself yields for free, and the
    /// rectangle the vision pass stored only when the page yields none.
    private nonisolated static func cropFor(
        _ figure: PaperFigureRecord,
        page: PDFPage,
        labelsPerPage: [Int: Int]
    ) -> PaperFigureRect? {
        #if os(macOS)
        return PaperFigureRectRefiner.displayedFigureCrop(
            forCaption: figure.caption,
            measured: figure.analysis?.figureRect,
            on: page,
            sharesPageWithOtherFigures: (labelsPerPage[figure.pageIndex] ?? 1) > 1
        )
        #else
        return figure.analysis?.figureRect
        #endif
    }
}
