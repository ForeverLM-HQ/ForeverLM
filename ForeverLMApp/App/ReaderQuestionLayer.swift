#if os(macOS)
import AppKit
import PDFKit
import SwiftUI

// MARK: - Reading questions on the paper's PDF
//
// docs/memory-design.md, "Mnemonic reading on the paper's PDF". A mnemonic
// reading made for a paper (or a book's chapters) is drawn on the PDF the
// Reader already shows, not read in a view of its own: each question is a
// small marker in the page margin beside the passage it follows, and a click
// opens the question as a card at the marker. The markers are views PDFKit
// lays over each page (`PDFPageOverlayViewProvider`), so they ride scrolling,
// zooming and Dark Mode and none is ever written to the file. They are not
// annotations: PDFKit paints an annotation at one pixel per PDF point and
// stretches it, so a glyph that small came out blurred at any zoom.
// The questions, and the answers, are the reading's (`ReaderQuestionsModel`).

/// Where a marker sits on its page.
enum ReaderQuestionMarkerGeometry {
    static let size: CGFloat = 16
    /// Points between the marker and the page's edge.
    static let inset: CGFloat = 5

    /// Whether a page's text runs in two columns: a good share of its lines
    /// start in the page's right half. A paragraph's short last line ends in
    /// the left half of a one-column page too, so one line cannot say.
    static func isTwoColumn(lines: [CGRect], page: CGRect) -> Bool {
        let wide = lines.filter { $0.width > 24 }
        guard wide.count >= 8 else { return false }
        let rightColumn = wide.filter { $0.minX >= page.midX - 4 }.count
        let leftColumn = wide.filter { $0.maxX <= page.midX + 4 }.count
        return rightColumn >= 4 && leftColumn >= 4
            && Double(rightColumn) >= Double(wide.count) * 0.25
            && Double(leftColumn) >= Double(wide.count) * 0.25
    }

    /// The marker for a passage whose last line is `line`, in the side margin
    /// nearest it: on a two-column page, the left margin for a line that ends
    /// in the page's left half (the left column's) and the right otherwise;
    /// on any other page, always the right. Clamped to the page; a marker that
    /// would cover one already placed on the page moves down the margin.
    static func rect(forLine line: CGRect, onPage page: CGRect, twoColumn: Bool = false, taken: [CGRect]) -> CGRect {
        let onLeft = twoColumn && line.maxX <= page.midX + 4
        let x = onLeft ? page.minX + inset : page.maxX - inset - size
        let lowest = page.minY + inset
        let highest = page.maxY - inset - size
        var rect = CGRect(x: x, y: line.midY - size / 2, width: size, height: size)
        rect.origin.y = min(max(rect.origin.y, lowest), highest)
        var moves = 0
        while moves < 8, taken.contains(where: { $0.insetBy(dx: -1, dy: -1).intersects(rect) }) {
            rect.origin.y -= size + 2
            moves += 1
        }
        rect.origin.y = min(max(rect.origin.y, lowest), highest)
        return rect
    }

    /// Whether the marker sits in the page's left margin, which decides the
    /// side its card opens on.
    static func isOnLeft(_ marker: CGRect, page: CGRect) -> Bool {
        marker.midX < page.midX
    }
}

@MainActor
final class ReaderQuestionLayer: NSObject, @preconcurrency PDFPageOverlayViewProvider {
    private struct Placement {
        let pageIndex: Int
        let line: CGRect
        let selection: PDFSelection
    }

    private struct PaintKey: Equatable {
        let id: String
        let standing: ReaderQuestionMarker.Standing
    }

    private weak var pdfView: PDFView?
    private weak var document: PDFDocument?
    private var desired: [ReaderQuestionMarker] = []
    private var placements: [String: Placement] = [:]
    /// Questions whose quote the PDF does not print; asked again only when the
    /// document changes.
    private var missed: Set<String> = []
    /// The markers each page carries, by page index, as last painted.
    private var marksByPage: [Int: [ReaderQuestionPageOverlay.Mark]] = [:]
    /// The overlays PDFKit shows now, one per page on screen.
    private var overlays: [ReaderQuestionPageOverlay] = []
    private var paintedKey: [PaintKey]?
    private var markerRects: [String: (pageIndex: Int, rect: CGRect)] = [:]
    /// Whether each page, by index, sets its text in two columns.
    private var twoColumnPages: [Int: Bool] = [:]
    private var placingTask: Task<Void, Never>?
    private var reportedOrder: [String]?

    private var popover: NSPopover?
    private var popoverQuestionID: String?
    private var closeObserver: NSObjectProtocol?
    private var flashed: PDFSelection?
    private var chip: NSHostingView<ReaderQuestionsChip>?
    private var chipCountersInversion = false
    /// What a click on a marker does; `apply` sets it, since it has the store.
    private var openQuestion: ((String) -> Void)?

    /// Created in the PDF coordinator's stored-property initialiser, which is
    /// not on any actor; everything it does afterwards is.
    nonisolated override init() {
        super.init()
    }

    // MARK: Drawing

    /// Draws `markers` on the PDF, finding each quote in the pages of its
    /// source's section a few at a time so a book is never searched in one
    /// go. Safe to call on every update: nothing is rebuilt unless a marker
    /// arrived, changed standing, or the learner hid them.
    func apply(
        markers: [ReaderQuestionMarker],
        visible: Bool,
        sections: [PDFDocumentSection],
        in pdfView: PDFView,
        store: ReaderQuestionsModel,
        storage: StorageService
    ) {
        self.pdfView = pdfView
        guard let document = pdfView.document else { return }
        if self.document !== document {
            reset()
            self.document = document
        }
        desired = markers
        openQuestion = { [weak self, weak store] questionID in
            guard let self, let store else { return }
            self.present(questionID, store: store, storage: storage)
        }
        ensureChip(in: pdfView, store: store, storage: storage)
        keepChipUpright(in: pdfView)
        let pending = markers.filter { placements[$0.questionID] == nil && !missed.contains($0.questionID) }
        if !pending.isEmpty {
            place(pending, sections: sections, in: document, store: store)
        } else if reportedOrder == nil || placingTask == nil {
            reportOrder(to: store)
        }
        repaint(visible: visible)
    }

    /// The document changed under the view: the marks belonged to the old one.
    func reset() {
        placingTask?.cancel()
        placingTask = nil
        close()
        clearMarks()
        placements = [:]
        missed = []
        paintedKey = nil
        markerRects = [:]
        twoColumnPages = [:]
        reportedOrder = nil
        document = nil
    }

    /// Takes everything down: the Reader closed or showed another source.
    func detach() {
        reset()
        chip?.removeFromSuperview()
        chip = nil
    }

    private func place(
        _ pending: [ReaderQuestionMarker],
        sections: [PDFDocumentSection],
        in document: PDFDocument,
        store: ReaderQuestionsModel
    ) {
        placingTask?.cancel()
        placingTask = Task { @MainActor [weak self, weak document, weak store] in
            var handled = 0
            for marker in pending {
                if Task.isCancelled { return }
                guard let self, let document else { return }
                if let section = sections.first(where: { $0.sourceID == marker.sourceID }) {
                    let range = section.pageRange.clamped(to: 0..<document.pageCount)
                    if let (page, selection) = ReaderPassageFlash.selection(for: marker.quote, in: document, pageRange: range) {
                        let line = selection.selectionsByLine().last?.bounds(for: page) ?? selection.bounds(for: page)
                        if !line.isNull, !line.isEmpty {
                            self.placements[marker.questionID] = Placement(
                                pageIndex: document.index(for: page),
                                line: line,
                                selection: selection
                            )
                        } else {
                            self.missed.insert(marker.questionID)
                        }
                    } else {
                        self.missed.insert(marker.questionID)
                    }
                } else {
                    self.missed.insert(marker.questionID)
                }
                handled += 1
                if handled % 6 == 0 {
                    self.repaint(visible: store?.isVisible ?? true)
                    await Task.yield()
                }
            }
            guard let self, let store, !Task.isCancelled else { return }
            self.placingTask = nil
            self.repaint(visible: store.isVisible)
            self.reportOrder(to: store)
        }
    }

    /// The placed questions top to bottom, for Next.
    private func reportOrder(to store: ReaderQuestionsModel) {
        let order = placements
            .sorted { lhs, rhs in
                if lhs.value.pageIndex != rhs.value.pageIndex { return lhs.value.pageIndex < rhs.value.pageIndex }
                if lhs.value.line.midY != rhs.value.line.midY { return lhs.value.line.midY > rhs.value.line.midY }
                return lhs.key < rhs.key
            }
            .map(\.key)
        guard order != reportedOrder else { return }
        reportedOrder = order
        // After the update that asked: the store is observed by the view.
        Task { @MainActor [weak store] in store?.notePlacement(order: order) }
    }

    private func repaint(visible: Bool) {
        guard let document else { return }
        let shown = visible ? desired.filter { placements[$0.questionID] != nil } : []
        let key = shown.map { PaintKey(id: $0.questionID, standing: $0.standing) }
        guard key != paintedKey else { return }
        paintedKey = key
        markerRects = [:]
        var byPage: [Int: [ReaderQuestionPageOverlay.Mark]] = [:]
        for marker in shown {
            guard let placement = placements[marker.questionID],
                  let page = document.page(at: placement.pageIndex) else { continue }
            let bounds = page.bounds(for: .cropBox)
            let rect = ReaderQuestionMarkerGeometry.rect(
                forLine: placement.line,
                onPage: bounds,
                twoColumn: isTwoColumn(page, index: placement.pageIndex),
                taken: byPage[placement.pageIndex]?.map(\.rect) ?? []
            )
            byPage[placement.pageIndex, default: []].append(.init(
                questionID: marker.questionID,
                rect: rect,
                standing: marker.standing
            ))
            markerRects[marker.questionID] = (placement.pageIndex, rect)
        }
        marksByPage = byPage
        for overlay in overlays { overlay.marks = marks(for: overlay.page) }
    }

    /// The markers a page of the current document carries; none for a page
    /// of a document the view no longer shows.
    private func marks(for page: PDFPage?) -> [ReaderQuestionPageOverlay.Mark] {
        guard let page, let document else { return [] }
        let index = document.index(for: page)
        guard index != NSNotFound else { return [] }
        return marksByPage[index] ?? []
    }

    private func isTwoColumn(_ page: PDFPage, index: Int) -> Bool {
        if let known = twoColumnPages[index] { return known }
        let bounds = page.bounds(for: .cropBox)
        let lines = page.selection(for: bounds)?.selectionsByLine().map { $0.bounds(for: page) } ?? []
        let result = ReaderQuestionMarkerGeometry.isTwoColumn(lines: lines, page: bounds)
        twoColumnPages[index] = result
        return result
    }

    private func clearMarks() {
        marksByPage = [:]
        markerRects = [:]
        for overlay in overlays { overlay.marks = [] }
    }

    // MARK: The overlays

    /// Every page gets an overlay, empty or not, so markers that land later
    /// have somewhere to go.
    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        let overlay = ReaderQuestionPageOverlay(page: page)
        overlay.onClick = { [weak self] questionID in self?.openQuestion?(questionID) }
        overlay.marks = marks(for: page)
        overlays.append(overlay)
        return overlay
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: NSView, for page: PDFPage) {
        overlays.removeAll { $0 === overlayView }
    }

    // MARK: The card

    /// Scrolls to a question's passage and opens its card there. Does nothing
    /// for a question the PDF does not print.
    func focus(_ questionID: String, store: ReaderQuestionsModel, storage: StorageService) {
        guard let pdfView, let document, let placement = placements[questionID],
              let page = document.page(at: placement.pageIndex) else { return }
        pdfView.go(to: placement.line.insetBy(dx: 0, dy: -140), on: page)
        ReaderPassageFlash.whenLaidOut(pdfView) { [weak self] _ in
            self?.present(questionID, store: store, storage: storage)
        }
    }

    /// Opens the question's card at its marker, with its quote marked.
    func present(_ questionID: String, store: ReaderQuestionsModel, storage: StorageService) {
        guard let pdfView, let document, let placement = placements[questionID],
              let page = document.page(at: placement.pageIndex),
              let entry = store.entry(for: questionID),
              let model = store.model(for: questionID),
              pdfView.window != nil else { return }
        if popoverQuestionID == questionID, popover?.isShown == true { return }
        close()
        store.noteOpened(questionID)

        placement.selection.color = ReaderPassageFlash.color()
        pdfView.highlightedSelections = (pdfView.highlightedSelections ?? []) + [placement.selection]
        flashed = placement.selection

        let markerRect = markerRects[questionID]?.rect ?? placement.line
        let anchor = pdfView.convert(markerRect, from: page)
        let onLeft = ReaderQuestionMarkerGeometry.isOnLeft(markerRect, page: page.bounds(for: .cropBox))

        let content = NSHostingController(rootView: ReaderQuestionPopoverContent(
            question: entry.question,
            model: model,
            storage: storage,
            onAnswered: { [weak self] in self?.closeSoon(questionID) }
        ))
        content.sizingOptions = .preferredContentSize
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = content
        popover.show(relativeTo: anchor, of: pdfView, preferredEdge: onLeft ? .maxX : .minX)
        self.popover = popover
        popoverQuestionID = questionID
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSPopover.didCloseNotification,
            object: popover,
            queue: .main
        ) { [weak self, weak popover] _ in
            MainActor.assumeIsolated {
                guard let self, let popover, self.popover === popover else { return }
                self.cardClosed()
            }
        }
    }

    func close() {
        let open = popover
        cardClosed()
        open?.close()
    }

    /// An answered card says what it kept for a moment, then goes.
    private func closeSoon(_ questionID: String) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1100))
            guard let self, self.popoverQuestionID == questionID else { return }
            self.close()
        }
    }

    private func cardClosed() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        popover = nil
        popoverQuestionID = nil
        if let flashed, let pdfView {
            pdfView.highlightedSelections = (pdfView.highlightedSelections ?? []).filter { $0 !== flashed }
        }
        flashed = nil
    }

    // MARK: The chip

    /// Dark Mode inverts the whole PDF view with a Core Image filter
    /// (`ReaderDarkMode`), and the chip is a subview of it. The same pair of
    /// filters on the chip's own layer undoes it: an inversion commutes with a
    /// hue rotation about the grey axis, so applied twice they cancel, and the
    /// chip keeps the colours it was drawn with.
    private func keepChipUpright(in pdfView: PDFView) {
        guard let chip else { return }
        let inverted = pdfView.layer?.filters?.isEmpty == false
        guard inverted != chipCountersInversion else { return }
        chipCountersInversion = inverted
        chip.wantsLayer = true
        if inverted {
            chip.layerUsesCoreImageFilters = true
            chip.layer?.filters = [
                CIFilter(name: "CIColorInvert"),
                CIFilter(name: "CIHueAdjust", parameters: [kCIInputAngleKey: Double.pi]),
            ].compactMap { $0 }
        } else {
            chip.layer?.filters = nil
            chip.layerUsesCoreImageFilters = false
        }
    }

    private func ensureChip(in pdfView: PDFView, store: ReaderQuestionsModel, storage: StorageService) {
        guard chip == nil else { return }
        let host = NSHostingView(rootView: ReaderQuestionsChip(store: store) { [weak self, weak store] in
            guard let self, let store, let next = store.nextUnansweredQuestionID() else { return }
            self.focus(next, store: store, storage: storage)
        })
        host.translatesAutoresizingMaskIntoConstraints = false
        pdfView.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: pdfView.topAnchor, constant: 10),
            host.trailingAnchor.constraint(equalTo: pdfView.trailingAnchor, constant: -22),
        ])
        chip = host
    }
}

// MARK: - The markers on a page

/// The view PDFKit lays over one page: the page's question markers, placed in
/// page points and drawn by AppKit at the screen's resolution. Clicks
/// anywhere else fall through to the page, for selecting text and following
/// links.
final class ReaderQuestionPageOverlay: NSView {
    struct Mark: Equatable {
        let questionID: String
        /// In page points, in the page's crop box.
        let rect: CGRect
        let standing: ReaderQuestionMarker.Standing
    }

    private(set) weak var page: PDFPage?
    var onClick: ((String) -> Void)?
    var marks: [Mark] = [] {
        didSet {
            guard marks != oldValue else { return }
            subviews.forEach { $0.removeFromSuperview() }
            for mark in marks {
                let marker = ReaderQuestionMarkerView(mark: mark)
                marker.onClick = { [weak self] in self?.onClick?(mark.questionID) }
                addSubview(marker)
            }
            needsLayout = true
        }
    }

    init(page: PDFPage) {
        self.page = page
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    /// The overlay covers the page at whatever zoom, so a marker's frame is
    /// its page rect scaled to the overlay.
    override func layout() {
        super.layout()
        guard let box = page?.bounds(for: .cropBox), box.width > 0, box.height > 0 else { return }
        let sx = bounds.width / box.width
        let sy = bounds.height / box.height
        for case let marker as ReaderQuestionMarkerView in subviews {
            let rect = marker.mark.rect
            marker.frame = CGRect(
                x: (rect.minX - box.minX) * sx,
                y: (rect.minY - box.minY) * sy,
                width: rect.width * sx,
                height: rect.height * sy
            )
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit is ReaderQuestionMarkerView ? hit : nil
    }
}

/// One question's marker: a filled circle with the question's standing in it,
/// drawn from SF Symbols so it stays sharp at any zoom.
final class ReaderQuestionMarkerView: NSView {
    /// The sepia the Studio gives the reading (`NotebookStudioHue.sepia`).
    private static let sepia = NSColor(calibratedRed: 0.70, green: 0.48, blue: 0.22, alpha: 1)
    private static let keptGreen = NSColor(calibratedRed: 0.28, green: 0.58, blue: 0.38, alpha: 1)

    let mark: ReaderQuestionPageOverlay.Mark
    var onClick: (() -> Void)?

    init(mark: ReaderQuestionPageOverlay.Mark) {
        self.mark = mark
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Question")
        setAccessibilityValue(Self.standingDescription(mark.standing))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Sepia **?** unanswered; green **✓** kept and not due; a sepia ring
    /// with **↻** on a pale fill, answered and due now.
    private static func layers(for standing: ReaderQuestionMarker.Standing) -> [(symbol: String, colors: [NSColor])] {
        switch standing {
        case .open: [("questionmark.circle.fill", [.white, sepia])]
        case .kept: [("checkmark.circle.fill", [.white, keptGreen])]
        case .due: [("circle.fill", [sepia.withAlphaComponent(0.16)]), ("arrow.clockwise.circle", [sepia])]
        }
    }

    private static func standingDescription(_ standing: ReaderQuestionMarker.Standing) -> String {
        switch standing {
        case .open: "Not answered"
        case .kept: "Answered"
        case .due: "Due for review"
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        for layer in Self.layers(for: mark.standing) {
            let configuration = NSImage.SymbolConfiguration(pointSize: bounds.height, weight: .semibold)
                .applying(.init(paletteColors: layer.colors))
            guard let image = NSImage(systemSymbolName: layer.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration),
                image.size.width > 0, image.size.height > 0 else { continue }
            let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
            let size = CGSize(width: image.size.width * fit, height: image.size.height * fit)
            image.draw(in: CGRect(
                x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2,
                width: size.width,
                height: size.height
            ))
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The press is the marker's, so PDFKit does not start a text selection.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

// MARK: - The card in the popover

/// The question as the reading shows it, in a popover at its marker.
private struct ReaderQuestionPopoverContent: View {
    let question: MnemonicQuestion
    let model: MnemonicReadingModel
    let storage: StorageService
    let onAnswered: () -> Void

    var body: some View {
        MnemonicQuestionCard(
            question: question,
            isUnplaced: false,
            model: model,
            storage: storage,
            onAnswered: onAnswered
        )
        .padding(10)
        .frame(width: 380)
        .onAppear {
            // A card opened from its marker is the one being answered.
            if model.memory[question.id] != nil { model.unfolded.insert(question.id) }
        }
    }
}

// MARK: - The chip

/// What the Reader says about a source's questions: how many, how many
/// answered, a switch to read the page bare, and Next Question.
struct ReaderQuestionsChip: View {
    let store: ReaderQuestionsModel
    let next: () -> Void

    var body: some View {
        if store.hasQuestions {
            let counts = store.counts()
            HStack(spacing: 4) {
                Button {
                    store.isVisible.toggle()
                } label: {
                    Image(systemName: store.isVisible ? "questionmark.circle.fill" : "questionmark.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(NotebookStudioHue.sepia.glyph)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(store.isVisible ? "Hide the reading questions" : "Show the reading questions")
                .accessibilityLabel(store.isVisible ? "Hide questions" : "Show questions")

                Text(Self.line(counts))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if store.isVisible, store.nextUnansweredQuestionID() != nil {
                    Button(action: next) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Next")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Go to the next question you have not answered")
                    .accessibilityLabel("Next question")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Reading questions")
        }
    }

    /// "18 questions", "3 of 18 answered", "3 of 18 answered · 2 due".
    static func line(_ counts: MnemonicReadingProgress.Counts) -> String {
        guard counts.answered > 0 else {
            return counts.questions == 1 ? "1 question" : "\(counts.questions) questions"
        }
        var line = "\(counts.answered) of \(counts.questions) answered"
        if counts.due > 0 { line += " · \(counts.due) due" }
        return line
    }
}
#endif
