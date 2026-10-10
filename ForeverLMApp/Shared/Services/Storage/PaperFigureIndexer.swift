#if os(macOS)
import Foundation
import OSLog
import PDFKit

private enum PaperFigureIndexerError: LocalizedError {
    case missingPDF(String)
    case unreadablePDF(String)

    var errorDescription: String? {
        switch self {
        case .missingPDF(let path): return "The paper PDF is not available at \(path)."
        case .unreadablePDF(let path): return "The paper PDF could not be opened at \(path)."
        }
    }
}

/// On-demand preparation of the local figure-to-page index and its vision
/// explanations. Only an explicit review request enters this actor; routine
/// import, launch, sync, and source-cleanup events merely leave durable queue
/// rows for a future review. Concurrent requests for one paper share one task.
actor PaperFigureIndexer {
    private let storage: StorageService
    private let aiService: AIService
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM",
        category: "PaperFigureIndexer"
    )
    private var inFlight: [String: Task<[PaperFigureRecord], Error>] = [:]
    /// Keyed by figure ID rather than source ID: two chats looking at two
    /// figures of one paper are not the same piece of work.
    private var inFlightFigures: [String: Task<[PaperFigureRecord], Error>] = [:]
    /// The callers waiting on each in-flight task, so a caller that is
    /// cancelled stops the vision pass when nobody else is waiting on it.
    private var waiters: [String: Set<UUID>] = [:]

    init(storage: StorageService, aiService: AIService) {
        self.storage = storage
        self.aiService = aiService
    }

    func prepare(sourceID: String) async throws -> [PaperFigureRecord] {
        try await prepare(sourceID: sourceID, analyzing: nil)
    }

    /// Prepare exactly one figure of a paper, for a reader who asked about that
    /// figure and nothing else.
    ///
    /// The structural half is free — it opens the PDF and reads the printed
    /// caption lines — so it runs whenever the paper has no index yet. The
    /// vision half costs a model call per figure, and someone who wants to look
    /// at Figure 3 should pay for Figure 3 rather than for every figure in the
    /// paper. That is the whole difference from `prepare(sourceID:)`, which a
    /// review of the entire paper still wants.
    func prepare(sourceID: String, figureLabel: String) async throws -> [PaperFigureRecord] {
        let requested = figureLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else { return try await storage.paperFigures(sourceID: sourceID) }

        var figures = try await storage.paperFigures(sourceID: sourceID)
        if figures.isEmpty {
            figures = try await prepare(sourceID: sourceID, analyzing: [requested])
        }
        guard let match = Self.figure(labelled: requested, in: figures) else { return figures }
        if let analysis = match.analysis, analysis.analysisVersion == PaperFigureAnalysis.currentVersion {
            return figures
        }
        guard let config = KeychainService.resolveConfig(for: .paperFigureUnderstanding) else {
            return figures
        }

        if let task = inFlightFigures[match.id] {
            return try await value(of: task, key: "figure:" + match.id)
        }
        let task = Task { [storage] in
            try await self.analyzeSingle(figure: match, config: config)
            return try await storage.paperFigures(sourceID: sourceID)
        }
        inFlightFigures[match.id] = task
        defer {
            if inFlightFigures[match.id] == task { inFlightFigures[match.id] = nil }
        }
        return try await value(of: task, key: "figure:" + match.id)
    }

    /// Waits for a shared task, and ends it when this caller is cancelled and
    /// no other caller is waiting on it. The task is unstructured, so without
    /// this a cancelled caller (the explainer's Cancel, a closed chat) kept
    /// waiting for every figure's vision call to finish: the banner stayed up
    /// and the spend went on for a result nobody would use.
    private func value(
        of task: Task<[PaperFigureRecord], Error>,
        key: String
    ) async throws -> [PaperFigureRecord] {
        let waiter = UUID()
        waiters[key, default: []].insert(waiter)
        defer {
            waiters[key]?.remove(waiter)
            if waiters[key]?.isEmpty == true { waiters[key] = nil }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            Task { await self.waiterCancelled(waiter, key: key, task: task) }
        }
    }

    private func waiterCancelled(
        _ waiter: UUID,
        key: String,
        task: Task<[PaperFigureRecord], Error>
    ) {
        waiters[key]?.remove(waiter)
        guard waiters[key]?.isEmpty ?? true else { return }
        task.cancel()
        // A caller arriving now must start its own pass, not join a cancelled one.
        if key.hasPrefix("figure:") {
            let figureID = String(key.dropFirst("figure:".count))
            if inFlightFigures[figureID] == task { inFlightFigures[figureID] = nil }
        } else if inFlight[key] == task {
            inFlight[key] = nil
        }
    }

    /// Build a paper's figure index without explaining anything.
    ///
    /// Reading the printed caption lines out of a PDF costs nothing but the read
    /// — no model, no credits, no sign-in — and it is all the cropping needs,
    /// because a caption is what says where its figure stops. This is what lets
    /// `show_source_image` hand back a cropped figure on a paper nobody has paid
    /// to have explained. Only `papers` have index rows, so this never walks a
    /// five-hundred-page book.
    func prepareStructure(sourceID: String) async throws -> [PaperFigureRecord] {
        try await prepare(sourceID: sourceID, analyzing: [])
    }

    /// The label match the tools use: case-folded, and blind to whether the
    /// paper prints "Fig." or "Figure".
    static func figure(labelled label: String, in figures: [PaperFigureRecord]) -> PaperFigureRecord? {
        let needle = label.lowercased().replacingOccurrences(of: "fig.", with: "figure")
        // `paperFigures` orders by page. A caption continued onto the next page
        // ("Fig. 3 | See next page for caption.") produces a second row with the
        // same label, and the figure itself is always the earlier one.
        return figures.first {
            $0.id == label
                || $0.figureLabel.lowercased().replacingOccurrences(of: "fig.", with: "figure") == needle
        }
    }

    private func prepare(
        sourceID: String,
        analyzing labels: Set<String>?
    ) async throws -> [PaperFigureRecord] {
        if let task = inFlight[sourceID] {
            return try await value(of: task, key: sourceID)
        }

        let existing = try await storage.paperFigures(sourceID: sourceID)
        let visionEnabled = KeychainService.resolveConfig(for: .paperFigureUnderstanding) != nil
        let needsVisionRefresh = visionEnabled && existing.contains {
            guard let analysis = $0.analysis else { return true }
            return analysis.analysisVersion != PaperFigureAnalysis.currentVersion
        }

        var candidate = try await storage.paperFigureIndexCandidate(sourceID: sourceID)
        if candidate == nil {
            try await storage.ensurePaperFigureIndexQueuedForReview(
                sourceID: sourceID,
                force: needsVisionRefresh
            )
            candidate = try await storage.paperFigureIndexCandidate(sourceID: sourceID)
        }
        guard let candidate else { return existing }

        let task = Task { [storage] in
            do {
                try await self.index(candidate, analyzing: labels)
                return try await storage.paperFigures(sourceID: candidate.sourceID)
            } catch {
                let indexingError = error
                // A stopped pass is not a failed one: the paper is left as it was.
                if indexingError is CancellationError || Task.isCancelled { throw indexingError }
                do {
                    try await storage.recordPaperFigureIndexFailure(
                        sourceID: candidate.sourceID,
                        message: indexingError.localizedDescription
                    )
                } catch {
                    throw AIError.apiError(
                        "Could not persist paper figure preparation failure: \(error.localizedDescription)"
                    )
                }
                self.logger.error(
                    "Figure preparation failed for \(candidate.sourceID): \(indexingError.localizedDescription)"
                )
                throw indexingError
            }
        }
        inFlight[sourceID] = task
        defer {
            if inFlight[sourceID] == task { inFlight[sourceID] = nil }
        }
        return try await value(of: task, key: sourceID)
    }

    private func index(
        _ candidate: PaperFigureIndexCandidate,
        analyzing labels: Set<String>?
    ) async throws {
        try Task.checkCancellation()
        guard let resolvedURL = SourceService.resolveLocalFileURL(candidate.pdfPath),
              FileManager.default.fileExists(atPath: resolvedURL.path) else {
            throw PaperFigureIndexerError.missingPDF(candidate.pdfPath)
        }
        guard let document = PDFDocument(url: resolvedURL) else {
            throw PaperFigureIndexerError.unreadablePDF(candidate.pdfPath)
        }

        let extracted = PDFTextExtractor.indexedFigures(
            from: document,
            pages: 0..<document.pageCount
        )
        let config = KeychainService.resolveConfig(for: .paperFigureUnderstanding)
        let existingByID = Dictionary(
            uniqueKeysWithValues: (try await storage.paperFigures(sourceID: candidate.sourceID))
                .map { ($0.id, $0) }
        )
        // Several figures routinely share one page, and the vision pass wants
        // that page's pixels once rather than once per label. The render is the
        // only copy that ever exists: nothing is written to disk.
        var pageRenders: [Int: PageRender] = [:]
        var figures: [PaperFigureRecord] = []
        let labelsPerPage = Dictionary(grouping: extracted, by: \.pageIndex)
            .mapValues { Set($0.map(\.figureLabel)).count }
        for figure in extracted {
            let figureID = PaperFigureIndexContract.figureID(
                sourceID: candidate.sourceID,
                figureLabel: figure.figureLabel,
                pageIndex: figure.pageIndex
            )
            let analysis: PaperFigureAnalysis?
            if let existing = existingByID[figureID]?.analysis,
               existing.analysisVersion == PaperFigureAnalysis.currentVersion {
                analysis = existing
            } else if let config, labels?.contains(figure.figureLabel) ?? true {
                let render: PageRender
                if let cached = pageRenders[figure.pageIndex] {
                    render = cached
                } else if let made = pageRender(from: document, pageIndex: figure.pageIndex) {
                    render = made
                    pageRenders[figure.pageIndex] = made
                } else {
                    throw PaperFigureIndexerError.unreadablePDF(candidate.pdfPath)
                }
                analysis = try await analyze(
                    figureID: figureID,
                    title: candidate.title,
                    figure: figure,
                    render: render,
                    sharesPageWithOtherFigures: (labelsPerPage[figure.pageIndex] ?? 1) > 1,
                    config: config
                )
            } else {
                // Three ways to reach here, all of them fine to store as
                // structure alone: no signed-in session, no credit consent yet,
                // or a targeted pass that is paying for one figure and leaving
                // the rest of the paper indexed but unexplained. Any of them can
                // be filled in later through the same durable path.
                analysis = nil
            }
            figures.append(PaperFigureRecord(
                id: PaperFigureIndexContract.figureID(
                    sourceID: candidate.sourceID,
                    figureLabel: figure.figureLabel,
                    pageIndex: figure.pageIndex
                ),
                sourceID: candidate.sourceID,
                figureLabel: figure.figureLabel,
                pageIndex: figure.pageIndex,
                caption: figure.caption,
                analysis: analysis
            ))
        }
        try Task.checkCancellation()
        try await storage.replacePaperFigureIndex(
            sourceID: candidate.sourceID,
            pdfPath: candidate.pdfPath,
            pageCount: document.pageCount,
            figures: figures,
            indexVersion: candidate.targetVersion
        )
        logger.info(
            "Indexed \(figures.count) figure(s) across \(document.pageCount) page(s) for \(candidate.sourceID)"
        )
    }

    /// One page's pixels, in the two forms the vision pass needs: the ruled
    /// JPEG the model reads, and the ink mask its answer is measured against.
    /// The page itself comes along because the caption anchor is text geometry,
    /// which only the page can supply.
    private struct PageRender {
        let page: PDFPage
        let imageData: Data
        let mask: PaperFigureRectRefiner.PageInkMask?
    }

    private func pageRender(from document: PDFDocument, pageIndex: Int) -> PageRender? {
        guard let page = document.page(at: pageIndex),
              let imageData = PDFTextExtractor.measuredPageJPEGData(
                from: document,
                pageIndex: pageIndex
              ) else { return nil }
        // The mask is drawn from the unruled page: the grid is the model's
        // measuring aid, and counting it as ink would put the crop's edges on
        // the gridlines instead of on the figure.
        return PageRender(
            page: page,
            imageData: imageData,
            mask: PaperFigureRectRefiner.mask(for: page)
        )
    }

    /// Run the vision pass for one already-indexed figure and keep just that
    /// row. The rest of the paper's index is untouched, which is what lets a
    /// chat pay per figure.
    private func analyzeSingle(figure: PaperFigureRecord, config: AITaskConfig) async throws {
        try Task.checkCancellation()
        var target = try await storage.paperFigureIndexCandidate(sourceID: figure.sourceID)
        if target == nil {
            // The usual case here: this paper's index finished, which deleted
            // its queue row, and only now is one of its figures being explained.
            target = try await storage.paperFigureIndexTarget(sourceID: figure.sourceID)
        }
        guard let candidate = target else {
            throw PaperFigureIndexerError.missingPDF(figure.sourceID)
        }
        guard let resolvedURL = SourceService.resolveLocalFileURL(candidate.pdfPath),
              FileManager.default.fileExists(atPath: resolvedURL.path) else {
            throw PaperFigureIndexerError.missingPDF(candidate.pdfPath)
        }
        guard let document = PDFDocument(url: resolvedURL) else {
            throw PaperFigureIndexerError.unreadablePDF(candidate.pdfPath)
        }
        guard let render = pageRender(from: document, pageIndex: figure.pageIndex) else {
            throw PaperFigureIndexerError.unreadablePDF(candidate.pdfPath)
        }
        let onPage = PDFTextExtractor.figureCaptionRecords(
            in: document.page(at: figure.pageIndex)?.string ?? ""
        )
        let analysis = try await analyze(
            figureID: figure.id,
            title: candidate.title,
            figure: PDFIndexedFigure(
                figureLabel: figure.figureLabel,
                pageIndex: figure.pageIndex,
                caption: figure.caption
            ),
            render: render,
            sharesPageWithOtherFigures: Set(onPage.map(\.label)).count > 1,
            config: config
        )
        try await storage.updatePaperFigureAnalysis(
            sourceID: figure.sourceID,
            figureID: figure.id,
            analysis: analysis
        )
        logger.info("Prepared \(figure.figureLabel) of \(figure.sourceID) on request")
    }

    private struct VisionResponse: Decodable {
        struct Rect: Decodable {
            let x: Double
            let y: Double
            let width: Double
            let height: Double

            var validated: PaperFigureRect? {
                let value = PaperFigureRect(x: x, y: y, width: width, height: height)
                return value.isValid ? value : nil
            }
        }

        struct Panel: Decodable {
            let label: String
            let explanation: String
            let rect: Rect?
        }

        let summary: String
        let visualEvidence: [String]
        let figureRect: Rect?
        let panels: [Panel]

        enum CodingKeys: String, CodingKey {
            case summary
            case visualEvidence = "visual_evidence"
            case figureRect = "figure_rect"
            case panels
        }
    }

    private func analyze(
        figureID: String,
        title: String,
        figure: PDFIndexedFigure,
        render: PageRender,
        sharesPageWithOtherFigures: Bool,
        config: AITaskConfig
    ) async throws -> PaperFigureAnalysis {
        let response = try await aiService.call(
            config: config,
            system: Prompts.paperFigureUnderstanding,
            user: """
            PAPER: \(title)
            TARGET: \(figure.figureLabel)
            PDF PAGE: \(figure.pageIndex + 1)
            CAPTION: \(figure.caption)
            """,
            maxTokens: 1_800,
            temperature: 0,
            imageJPEGData: render.imageData,
            jsonMode: true,
            sourceTitle: title,
            subjectID: figureID,
            subjectType: "paper_figure"
        )
        let decoded = try JSONDecoder().decode(VisionResponse.self, from: Data(response.utf8))
        let summary = decoded.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else {
            throw KnowledgeStoreError.invalidData("Paper figure analysis returned an empty summary.")
        }
        let panels = decoded.panels.enumerated().compactMap { index, panel -> PaperFigurePanel? in
            let label = panel.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let explanation = panel.explanation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, !explanation.isEmpty else { return nil }
            return PaperFigurePanel(
                id: "\(figureID)-panel-\(index + 1)",
                label: label,
                explanation: explanation,
                rect: panel.rect?.validated
            )
        }
        // Neighbouring panels' rectangles overlap as read by eye, which puts
        // one panel's heading along the foot of the next; they are split at
        // the white gutter between them before each is trimmed.
        var measuredPanels: [String: PaperFigureRect] = [:]
        for panel in panels {
            if let rect = panel.rect { measuredPanels[panel.id] = rect }
        }
        let separatedPanels = render.mask.map {
            PaperFigureRectRefiner.separatedPanelRects(measuredPanels, with: $0)
        } ?? measuredPanels
        let place = render.mask.map { figurePlace(of: figure, on: render.page, mask: $0) }
        return PaperFigureAnalysis(
            summary: summary,
            visualEvidence: decoded.visualEvidence
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            figureRect: refinedFigureRect(
                decoded.figureRect?.validated,
                render: render,
                place: place,
                sharesPageWithOtherFigures: sharesPageWithOtherFigures
            ),
            panels: panels.map { panel in
                guard let rect = separatedPanels[panel.id] ?? panel.rect else { return panel }
                // A panel is only ever trimmed, never grown. Slack is the common
                // failure and trimming is free of risk; growing a panel could
                // reach into the one beside it, and showing the wrong panel is
                // worse than showing a loose crop of the right one.
                return PaperFigurePanel(
                    id: panel.id,
                    label: panel.label,
                    explanation: panel.explanation,
                    rect: refinedFigureRect(
                        rect,
                        render: render,
                        place: place,
                        sharesPageWithOtherFigures: true,
                        allowsGrowth: false
                    ) ?? rect
                )
            },
            analysisVersion: PaperFigureAnalysis.currentVersion,
            generatedAt: Date()
        )
    }

    /// Where the page puts a figure: its caption's line, or — when the page
    /// prints neither the caption nor the figure's label — its prose-free
    /// band, and the region between them and the prose, legends and other
    /// figures around it (`PaperFigureRectRefiner.figureRegion`). Read once
    /// a figure: its panels are refined in the same place.
    private struct FigurePlace {
        let captionBounds: CGRect?
        let fallbackBand: CGRect?
        let region: PaperFigureRectRefiner.FigureRegion?
    }

    private func figurePlace(
        of figure: PDFIndexedFigure,
        on page: PDFPage,
        mask: PaperFigureRectRefiner.PageInkMask
    ) -> FigurePlace {
        let captionBounds = PaperFigureRectRefiner.captionAnchor(of: figure.caption, on: page)
        let fallbackBand = captionBounds == nil
            ? PaperFigureRectRefiner.uncaptionedFigureBand(on: page, mask: mask)
            : nil
        return FigurePlace(
            captionBounds: captionBounds,
            fallbackBand: fallbackBand,
            region: PaperFigureRectRefiner.figureRegion(
                captionAnchor: captionBounds,
                fallbackBand: fallbackBand,
                on: page,
                mask: mask
            )
        )
    }

    /// Put the model's rectangle back on the page's own ink. The model reads
    /// coordinates off a ruled page, which is far better than estimating them,
    /// but a reading is still not a measurement.
    ///
    /// When the page can be measured, its answer stands — including a nil, which
    /// means the crop would have been the page and the reader should just be
    /// shown the page. The model's own rectangle survives only where there is
    /// nothing to measure against. It is refined inside the figure's region,
    /// as the free crop is, so a rectangle that fell short never grows into
    /// the prose, the legends or the other figures around it; a page whose
    /// text places no region falls back to the band on the caption's side.
    private func refinedFigureRect(
        _ rect: PaperFigureRect?,
        render: PageRender,
        place: FigurePlace?,
        sharesPageWithOtherFigures: Bool,
        allowsGrowth: Bool = true
    ) -> PaperFigureRect? {
        guard let mask = render.mask, let place else { return rect }
        return PaperFigureRectRefiner.refined(
            rect,
            captionBounds: place.captionBounds,
            pageBounds: render.page.bounds(for: .mediaBox),
            with: mask,
            sharesPageWithOtherFigures: sharesPageWithOtherFigures,
            allowsGrowth: allowsGrowth,
            figureSide: place.region == nil
                ? place.captionBounds.flatMap { PaperFigureRectRefiner.figureSide(captionBounds: $0, on: render.page) }
                : nil,
            fallbackBand: place.fallbackBand,
            region: place.region
        )
    }
}


/// Removes the rendered page JPEGs that figure indexing wrote before schema 75.
///
/// This is deletion of the user's files, so it is deliberately narrow. It only
/// enters directories named `Figures` that sit under a known content root, and
/// it only removes one when *every* regular file beneath it is a `page-NNNN.jpg`
/// this app generated. A `Figures` folder holding anything else is somebody's
/// own, and is left exactly where it is.
///
/// The walk runs off the main actor and yields between directories: it is a full
/// traversal of the content roots, which on a real library means gigabytes of
/// metadata, and it must never be what makes the app stutter.
enum PaperFigureImageSweeper {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM",
        category: "PaperFigureImageSweeper"
    )

    /// Directories removed, for the caller to record and log.
    static func sweep() async -> Int {
        await sweep(roots: StorageService.knownContentRoots)
    }

    /// Root list injected so the destructive half can be exercised against a
    /// temporary tree rather than the learner's library.
    static func sweep(roots: [String]) async -> Int {
        var removed = 0
        var visitedRoots = Set<String>()
        for root in roots {
            let standardized = URL(fileURLWithPath: root, isDirectory: true)
                .standardizedFileURL
            guard visitedRoots.insert(standardized.path).inserted,
                  FileManager.default.fileExists(atPath: standardized.path) else { continue }
            removed += await sweepDirectory(standardized, depth: 0)
        }
        return removed
    }

    /// Deep enough for any real content root — the observed maximum on a large
    /// library is six — and a hard stop against a pathological tree.
    private static let maximumSweepDepth = 12

    private static func sweepDirectory(_ directory: URL, depth: Int) async -> Int {
        guard !Task.isCancelled, depth <= maximumSweepDepth else { return 0 }
        await Task.yield()

        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return 0
        }

        var removed = 0
        for entry in contents {
            let values = try? entry.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values?.isDirectory == true else { continue }
            // Never walk a link. A content root under a synced or redirected
            // home directory can point anywhere, and following one turns a
            // bounded sweep into a traversal of somebody else's disk — or a
            // loop.
            guard values?.isSymbolicLink != true else { continue }

            if entry.lastPathComponent == "Figures" {
                // Never descend into a candidate: either it is entirely ours and
                // goes as one unit, or it is not ours and is not touched.
                if holdsOnlyGeneratedPageImages(entry) {
                    do {
                        try FileManager.default.removeItem(at: entry)
                        removed += 1
                    } catch {
                        logger.error(
                            "Could not remove \(entry.path): \(error.localizedDescription)"
                        )
                    }
                } else {
                    logger.notice("Left \(entry.path) alone: it holds files this app did not write")
                }
                continue
            }
            removed += await sweepDirectory(entry, depth: depth + 1)
        }
        return removed
    }

    /// True when every regular file beneath `directory` is a generated
    /// `page-NNNN.jpg`. An empty tree qualifies — that is a leftover shell.
    private static func holdsOnlyGeneratedPageImages(_ directory: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else { return false }

        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            guard isGeneratedPageImageName(url.lastPathComponent) else { return false }
        }
        return true
    }

    private static func isGeneratedPageImageName(_ name: String) -> Bool {
        // macOS drops .DS_Store into any browsed folder; it is not evidence that
        // the directory holds anything of the user's.
        if name == ".DS_Store" { return true }
        guard name.hasPrefix("page-"), name.hasSuffix(".jpg") else { return false }
        let digits = name.dropFirst("page-".count).dropLast(".jpg".count)
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }
}

#endif
