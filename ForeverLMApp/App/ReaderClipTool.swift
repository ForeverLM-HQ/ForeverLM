#if os(macOS)
import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    /// The Reader ⋯ menu's Clip item: turns the Clip tool on or off in the
    /// PDF view showing `sourceID` in the key window.
    static let readerClipToolToggle = Notification.Name("ForeverLM.readerClipToolToggle")
}

/// The Clip tool over a PDF in the Reader: a box drawn round part of a page
/// (a figure, a panel, a table), dragged out to the Canvas or saved, that
/// remembers the source, the page and the region it came from
/// (docs/knowledge-map-design.md, "Clips").
///
/// Turned on by Clip in the Reader's ⋯ menu, or for one box by ⌥-dragging on a
/// page. A drag draws the box; a click on an indexed figure snaps the box to
/// the panel under the pointer, and a second click to the whole figure. The
/// box names what it holds from the paper's figure index ("Figure 2B ·
/// Membrane potential…"), so a clip is never anonymous. Nothing is saved
/// until the clip is dropped on the Canvas or the learner presses Save Clip.
@MainActor
final class ReaderClipTool: NSObject {
    /// What the tool asks of the reader that hosts it.
    struct Host {
        /// The source a page of the document belongs to, and the page's
        /// zero-based index in that source's own PDF: a book read as one
        /// document is filed by chapter, as its highlights are.
        var sourcePage: @MainActor (PDFPage) -> (sourceID: String, pageIndex: Int)?
        var sourceIDs: @MainActor () -> [String]
    }

    /// A box as drawn: the document page it is on and its rectangle in that
    /// page's own coordinates (PDF points, bottom-left origin).
    struct Box: Equatable {
        let page: PDFPage
        var rect: CGRect
    }

    private weak var pdfView: PDFView?
    private weak var vm: StudioViewModel?
    private var host: Host?
    private var overlay: ReaderClipOverlayView?
    private var scrollObserver: NSObjectProtocol?
    private var toggleObserver: NSObjectProtocol?
    private(set) var isOn = false
    /// On for one box only (⌥-drag): off again once the box is dragged out,
    /// saved or cleared.
    private var transient = false
    private(set) var box: Box?
    /// What the box holds: its clip as it would be dragged or saved, once
    /// worked out, and whether it was saved already.
    private(set) var clip: StudioClipTransfer?
    private var clipImage: Data?
    private var savedHighlightID: String?
    private var nameTask: Task<Void, Never>?
    /// The figure index's resolver for each source, and each page's figures
    /// as boxes, read once.
    private var resolvers: [String: WalkthroughAnchorResolver] = [:]
    private var regions: [String: [Int: [ReaderClipFigureRegion]]] = [:]

    /// Made by the PDF view's coordinator, which is not on the main actor;
    /// everything after runs there.
    nonisolated override init() {
        super.init()
    }

    func attach(to pdfView: PDFView, vm: StudioViewModel, host: Host) {
        self.pdfView = pdfView
        self.vm = vm
        self.host = host
        if toggleObserver == nil {
            toggleObserver = NotificationCenter.default.addObserver(
                forName: .readerClipToolToggle, object: nil, queue: .main
            ) { [weak self] note in
                let sourceID = note.userInfo?["sourceID"] as? String
                MainActor.assumeIsolated { self?.toggleRequested(sourceID: sourceID) }
            }
        }
        (pdfView as? FindablePDFView)?.optionDragStarted = { [weak self] event in
            self?.beginOneBox(with: event)
        }
    }

    func update(host: Host) {
        self.host = host
    }

    func detach() {
        turnOff()
        if let toggleObserver { NotificationCenter.default.removeObserver(toggleObserver) }
        toggleObserver = nil
        (pdfView as? FindablePDFView)?.optionDragStarted = nil
        pdfView = nil
    }

    /// The document changed under the view: boxes and figures belong to the old one.
    func reset() {
        clearBox()
        resolvers = [:]
        regions = [:]
    }

    // MARK: On and off

    private func toggleRequested(sourceID: String?) {
        guard let pdfView, let window = pdfView.window, window.isKeyWindow,
              let host, sourceID.map({ host.sourceIDs().contains($0) }) ?? true else { return }
        if isOn { turnOff() } else { turnOn(transient: false) }
    }

    func turnOn(transient: Bool) {
        // A clip goes to the Canvas, so there is no clipping where the
        // Canvas does not show (`BetaFeatures`); ⌥-drag selects text there.
        guard let pdfView, BetaFeatures.showsCanvas else { return }
        self.transient = transient
        guard !isOn else { return }
        isOn = true
        let overlay = ReaderClipOverlayView(tool: self)
        overlay.frame = pdfView.bounds
        overlay.autoresizingMask = [.width, .height]
        pdfView.addSubview(overlay)
        self.overlay = overlay
        overlay.keepUpright(in: pdfView)
        pdfView.window?.makeFirstResponder(overlay)
        observeScrolling(in: pdfView)
        overlay.showHint(!transient)
        prefetchRegions()
        vm?.readerClipToolChanged(isOn: true)
    }

    func turnOff() {
        guard isOn else { return }
        isOn = false
        clearBox()
        overlay?.removeFromSuperview()
        overlay = nil
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        if let pdfView { pdfView.window?.makeFirstResponder(pdfView) }
        vm?.readerClipToolChanged(isOn: false)
    }

    /// ⌥-drag on a page: the tool for this one box. Returns the view the
    /// rest of the drag goes to, since AppKit keeps sending it to the view
    /// that took the press.
    private func beginOneBox(with event: NSEvent) -> NSView? {
        guard let pdfView, BetaFeatures.showsCanvas else { return nil }
        let point = pdfView.convert(event.locationInWindow, from: nil)
        guard pdfView.page(for: point, nearest: false) != nil else { return nil }
        if !isOn { turnOn(transient: true) }
        overlay?.mouseDown(with: event)
        return overlay
    }

    /// The overlay follows the pages as they scroll and zoom.
    private func observeScrolling(in pdfView: PDFView) {
        guard let clip = pdfView.documentView?.enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.overlay?.layoutBox() }
        }
    }

    func viewChanged() {
        overlay?.layoutBox()
        if let pdfView { overlay?.keepUpright(in: pdfView) }
    }

    // MARK: The box

    /// A box finished: snapped to a figure, or drawn by hand. Works out its
    /// clip (the source's page and the normalized region) and names it.
    func setBox(_ box: Box?) {
        nameTask?.cancel()
        savedHighlightID = nil
        clipImage = nil
        guard let box, box.page.rotation % 360 == 0, box.rect.width >= 4, box.rect.height >= 4,
              let place = host?.sourcePage(box.page) else {
            self.box = nil
            clip = nil
            overlay?.layoutBox()
            if box?.page.rotation ?? 0 != 0 { vm?.showToast("A turned page can't be clipped yet") }
            return
        }
        self.box = box
        let crop = Self.normalized(box.rect, on: box.page)
        let image = WalkthroughAnchorResolver.renderLens(crop, on: box.page, pixelSize: 1_600, maximumScale: 4, lossless: true)
        clipImage = image
        let pixels = image.flatMap { NSBitmapImageRep(data: $0) }
        let page = place.pageIndex + 1
        clip = StudioClipTransfer(
            sourceID: place.sourceID,
            page: page,
            crop: crop,
            title: "Page \(page)",
            pixelWidth: pixels?.pixelsWide ?? 0,
            pixelHeight: pixels?.pixelsHigh ?? 0,
            highlightID: nil
        )
        overlay?.layoutBox()
        nameTask = Task { [weak self] in
            guard let self else { return }
            let found = await self.regions(sourceID: place.sourceID, pageIndex: place.pageIndex)
            guard !Task.isCancelled, self.clip?.crop == crop else { return }
            let match = ReaderClipMatch.match(crop, in: found)
            self.clip?.title = ReaderClipMatch.title(for: match, page: page)
            self.overlay?.layoutBox()
        }
    }

    /// A click on the page: the box snaps to the panel or figure under it.
    /// Nil when there is no indexed figure there.
    func snap(at point: CGPoint, on page: PDFPage) async -> CGRect? {
        guard let place = host?.sourcePage(page) else { return nil }
        let found = await regions(sourceID: place.sourceID, pageIndex: place.pageIndex)
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let x = (point.x - bounds.minX) / bounds.width
        let y = (bounds.maxY - point.y) / bounds.height
        let current = box.flatMap { $0.page === page ? Self.normalized($0.rect, on: page) : nil }
        guard let rect = ReaderClipMatch.snap(x: x, y: y, in: found, current: current) else { return nil }
        return Self.pageRect(rect, on: page)
    }

    func clearBox() {
        nameTask?.cancel()
        box = nil
        clip = nil
        clipImage = nil
        savedHighlightID = nil
        overlay?.layoutBox()
    }

    /// Done with the box: cleared, and the tool off again if it was on for
    /// this box only.
    func finishBox() {
        clearBox()
        if transient { turnOff() }
    }

    // MARK: Saving, copying, dragging

    /// Saves the clip without placing it: it waits in the Canvas's Library.
    func save() {
        guard var clip, let vm else { return }
        if savedHighlightID == nil {
            // The id a drag or a copy already gave it, so a paste of that
            // copy finds this clip rather than making a second.
            let id = clip.highlightID ?? SourceHighlight.newID()
            clip.highlightID = id
            savedHighlightID = id
            self.clip = clip
            Task { await vm.saveReaderClip(clip, announce: true) }
        }
        finishBox()
    }

    /// The clip on the pasteboard: the picture for any app, and the clip for
    /// the Canvas.
    func copy() {
        guard let item = pasteboardItem() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
        vm?.showToast("Clip copied")
    }

    func pasteboardItem() -> NSPasteboardItem? {
        guard var clip else { return nil }
        // A clip dragged or copied twice is one clip: the first drop saves it
        // under this id, the second finds it.
        if clip.highlightID == nil {
            clip.highlightID = SourceHighlight.newID()
            self.clip = clip
        }
        let item = NSPasteboardItem()
        if let data = try? JSONEncoder().encode(clip) {
            item.setData(data, forType: NSPasteboard.PasteboardType(UTType.studioClip.identifier))
        }
        if let clipImage { item.setData(clipImage, forType: .png) }
        return item
    }

    var dragImage: NSImage? {
        clipImage.flatMap(NSImage.init(data:))
    }

    // MARK: Figures

    private func prefetchRegions() {
        guard let pdfView, let page = pdfView.currentPage, let place = host?.sourcePage(page) else { return }
        Task { _ = await regions(sourceID: place.sourceID, pageIndex: place.pageIndex) }
    }

    /// One page's figures as boxes, from the paper's figure index: its
    /// structure is read first when the paper has none yet (free: no model).
    private func regions(sourceID: String, pageIndex: Int) async -> [ReaderClipFigureRegion] {
        if let cached = regions[sourceID]?[pageIndex] { return cached }
        guard let resolver = await resolver(for: sourceID) else { return [] }
        let found = await resolver.clipRegions(onPage: pageIndex)
        regions[sourceID, default: [:]][pageIndex] = found
        return found
    }

    private func resolver(for sourceID: String) async -> WalkthroughAnchorResolver? {
        if let resolver = resolvers[sourceID] { return resolver }
        guard let vm, let article = await vm.persistedArticle(forLinkToken: sourceID),
              article.sourceType == .paper else { return nil }
        let figures: [PaperFigureRecord]
        do {
            figures = try await vm.paperFigureIndexer.prepareStructure(sourceID: sourceID)
        } catch {
            return nil
        }
        let path = await Task.detached(priority: .userInitiated) { article.resolvedLocalPath }.value
        let resolver = resolvers[sourceID] ?? WalkthroughAnchorResolver(figures: figures, pdfPath: path)
        resolvers[sourceID] = resolver
        return resolver
    }

    // MARK: Geometry

    /// A rectangle in page space as a fraction of the page's media box, with a
    /// top-left origin: the frame `SourceImageReference` crops in.
    nonisolated static func normalized(_ rect: CGRect, on page: PDFPage) -> PaperFigureRect {
        let bounds = page.bounds(for: .mediaBox)
        let clipped = rect.intersection(bounds)
        guard bounds.width > 0, bounds.height > 0, !clipped.isNull else {
            return PaperFigureRect(x: 0, y: 0, width: 0, height: 0)
        }
        func rounded(_ value: CGFloat) -> Double { (Double(value) * 10_000).rounded() / 10_000 }
        return PaperFigureRect(
            x: rounded((clipped.minX - bounds.minX) / bounds.width),
            y: rounded((bounds.maxY - clipped.maxY) / bounds.height),
            width: rounded(clipped.width / bounds.width),
            height: rounded(clipped.height / bounds.height)
        )
    }

    nonisolated static func pageRect(_ rect: PaperFigureRect, on page: PDFPage) -> CGRect {
        let bounds = page.bounds(for: .mediaBox)
        return CGRect(
            x: bounds.minX + rect.x * bounds.width,
            y: bounds.maxY - (rect.y + rect.height) * bounds.height,
            width: rect.width * bounds.width,
            height: rect.height * bounds.height
        )
    }
}

// MARK: - The overlay

/// Drawn over the PDF view while the Clip tool is on: the box (or the box
/// being drawn), a veil over the rest of the page, the clip's name and
/// actions under the box, and a hint at the top while nothing is boxed.
/// Takes the pointer only over pages and the box, so the scroller and the
/// gutter still work; scrolling and pinching pass through to the PDF view.
final class ReaderClipOverlayView: NSView, NSDraggingSource {
    private weak var tool: ReaderClipTool?
    private var drawing: (page: PDFPage, start: CGPoint, current: CGPoint)?
    private var pressInBox: NSPoint?
    private var pill: NSHostingView<ReaderClipPill>?
    private var hint: NSHostingView<ReaderClipHint>?
    private var countersInversion = false

    init(tool: ReaderClipTool) {
        self.tool = tool
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    private var pdfView: PDFView? { superview as? PDFView }

    override var isFlipped: Bool { pdfView?.isFlipped ?? false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Dark Mode inverts the whole PDF view (`ReaderDarkMode`); the same pair
    /// of filters on this layer undoes it, as the questions chip does.
    func keepUpright(in pdfView: PDFView) {
        let inverted = pdfView.layer?.filters?.isEmpty == false
        guard inverted != countersInversion else { return }
        countersInversion = inverted
        if inverted {
            layerUsesCoreImageFilters = true
            layer?.filters = [
                CIFilter(name: "CIColorInvert"),
                CIFilter(name: "CIHueAdjust", parameters: [kCIInputAngleKey: Double.pi]),
            ].compactMap { $0 }
        } else {
            layer?.filters = nil
            layerUsesCoreImageFilters = false
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let pdfView, let superview else { return nil }
        let local = convert(point, from: superview)
        if let hit = super.hitTest(point), hit !== self { return hit }
        if let box = boxRectInView(), box.contains(local) { return self }
        return pdfView.page(for: local, nearest: false) == nil ? nil : self
    }

    // MARK: Drawing

    private func boxRectInView() -> CGRect? {
        guard let pdfView else { return nil }
        if let drawing {
            let rect = CGRect(
                x: min(drawing.start.x, drawing.current.x), y: min(drawing.start.y, drawing.current.y),
                width: abs(drawing.current.x - drawing.start.x), height: abs(drawing.current.y - drawing.start.y)
            )
            return pdfView.convert(rect, from: drawing.page)
        }
        guard let box = tool?.box else { return nil }
        return pdfView.convert(box.rect, from: box.page)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let rect = boxRectInView() else { return }
        let accent = NSColor.controlAccentColor
        // A light veil over everything but the box, so the clip reads as cut out.
        let veil = NSBezierPath(rect: bounds)
        veil.append(NSBezierPath(rect: rect).reversed)
        NSColor.black.withAlphaComponent(0.18).setFill()
        veil.fill()
        let outline = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1))
        outline.lineWidth = 2
        if drawing != nil { outline.setLineDash([6, 4], count: 2, phase: 0) }
        accent.setStroke()
        outline.stroke()
    }

    /// Redraws the box where the page now is, and moves the pill under it.
    func layoutBox() {
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        guard let rect = boxRectInView(), drawing == nil, let clip = tool?.clip else {
            pill?.removeFromSuperview()
            pill = nil
            return
        }
        hint?.removeFromSuperview()
        hint = nil
        let view = ReaderClipPill(
            title: clip.title,
            save: { [weak self] in self?.tool?.save() },
            copy: { [weak self] in self?.tool?.copy() },
            close: { [weak self] in self?.tool?.finishBox() }
        )
        if let pill { pill.rootView = view } else {
            let host = NSHostingView(rootView: view)
            addSubview(host)
            pill = host
        }
        guard let pill else { return }
        let size = pill.fittingSize
        // Under the box, or over it when the box reaches the bottom; kept inside the view.
        let below = isFlipped ? rect.maxY + 8 : rect.minY - 8 - size.height
        let above = isFlipped ? rect.minY - 8 - size.height : rect.maxY + 8
        let fitsBelow = isFlipped ? below + size.height <= bounds.maxY - 6 : below >= bounds.minY + 6
        var origin = CGPoint(x: rect.midX - size.width / 2, y: fitsBelow ? below : above)
        origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - size.width - 24)
        origin.y = min(max(origin.y, bounds.minY + 6), bounds.maxY - size.height - 6)
        pill.frame = CGRect(origin: origin, size: size)
    }

    func showHint(_ shows: Bool) {
        hint?.removeFromSuperview()
        hint = nil
        guard shows else { return }
        let host = NSHostingView(rootView: ReaderClipHint(close: { [weak self] in self?.tool?.turnOff() }))
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.centerXAnchor.constraint(equalTo: centerXAnchor),
            host.topAnchor.constraint(equalTo: topAnchor, constant: 10),
        ])
        hint = host
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        if let rect = boxRectInView(), drawing == nil, tool?.clip != nil {
            addCursorRect(rect.intersection(bounds), cursor: .openHand)
        }
    }

    // MARK: Pointer

    override func mouseDown(with event: NSEvent) {
        guard let pdfView else { return }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if let rect = boxRectInView(), rect.contains(point), tool?.clip != nil {
            pressInBox = point
            return
        }
        guard let page = pdfView.page(for: point, nearest: true) else { return }
        let start = pdfView.convert(point, to: page)
        drawing = (page, start, start)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let press = pressInBox {
            guard hypot(point.x - press.x, point.y - press.y) > 3 else { return }
            pressInBox = nil
            beginDrag(with: event)
            return
        }
        guard let pdfView, var drawing else { return }
        // The box stays on the page it was started on, clamped to that page.
        let bounds = drawing.page.bounds(for: .mediaBox)
        var current = pdfView.convert(point, to: drawing.page)
        current.x = min(max(current.x, bounds.minX), bounds.maxX)
        current.y = min(max(current.y, bounds.minY), bounds.maxY)
        drawing.current = current
        self.drawing = drawing
        pill?.removeFromSuperview()
        pill = nil
        needsDisplay = true
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        pressInBox = nil
        guard let drawing, let tool else { return }
        self.drawing = nil
        let rect = CGRect(
            x: min(drawing.start.x, drawing.current.x), y: min(drawing.start.y, drawing.current.y),
            width: abs(drawing.current.x - drawing.start.x), height: abs(drawing.current.y - drawing.start.y)
        )
        // A drag of a few points is a click: the box snaps to the figure under it.
        let scale = pdfView?.scaleFactor ?? 1
        if rect.width * scale < 6 && rect.height * scale < 6 {
            let page = drawing.page
            Task { @MainActor [weak self, weak tool] in
                guard let tool else { return }
                if let snapped = await tool.snap(at: drawing.start, on: page) {
                    tool.setBox(.init(page: page, rect: snapped))
                } else {
                    tool.clearBox()
                }
                self?.needsDisplay = true
            }
            needsDisplay = true
            return
        }
        tool.setBox(.init(page: drawing.page, rect: rect))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape: the box first, then the tool.
            if tool?.box != nil { tool?.finishBox() } else { tool?.turnOff() }
        case 36, 76: // Return: Save Clip.
            tool?.save()
        default:
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" {
                tool?.copy()
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override func magnify(with event: NSEvent) {
        pdfView?.magnify(with: event)
    }

    // MARK: Dragging the clip out

    private func beginDrag(with event: NSEvent) {
        guard let tool, let item = tool.pasteboardItem(), let rect = boxRectInView() else { return }
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let image = tool.dragImage ?? NSImage(size: rect.size)
        // Shown at the size it is on the page, at most 360 points wide.
        let width = min(rect.width, 360)
        let size = NSSize(width: width, height: rect.height * width / max(rect.width, 1))
        let origin = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        dragging.setDraggingFrame(CGRect(origin: origin, size: size), contents: image)
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .copy : [.copy]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Dropped somewhere that took it: the box has done its work. After
        // the session, since finishing may take this view away.
        guard operation != [] else { return }
        DispatchQueue.main.async { [weak self] in self?.tool?.finishBox() }
    }
}

// MARK: - Its controls

/// Under the box: what the clip is, and Save Clip, Copy and ×. The box itself
/// is the drag handle.
struct ReaderClipPill: View {
    let title: String
    let save: () -> Void
    let copy: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.draw")
                .foregroundStyle(.secondary)
                .help("Drag the box onto the Canvas")
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: 280, alignment: .leading)
            Divider().frame(height: 14)
            Button("Save Clip", action: save)
                .help("Keep this clip; it waits in the Canvas's Library (Return)")
            Button(action: copy) { Image(systemName: "doc.on.doc") }
                .help("Copy the picture (⌘C)")
            Button(action: close) { Image(systemName: "xmark") }
                .help("Clear the box (Esc)")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .fixedSize()
    }
}

/// At the top while the tool is on and nothing is boxed.
struct ReaderClipHint: View {
    let close: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "scissors")
            Text("Drag a box round a figure, or click one to pick it, then drag it onto the Canvas")
                .font(.system(size: 12))
            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Stop clipping (Esc)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .fixedSize()
    }
}
#endif
