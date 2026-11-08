import AppKit
import CoreImage
import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import WebKit

// MARK: - Prose presentation

/// How the inline text reader sets text that was written to be read rather
/// than consulted — an explainer's script today. The transcript form the
/// reader otherwise takes is a full-width system-font dump, which is right for
/// a podcast's raw text and wrong for an essay: this puts the script in a
/// measured serif column with a masthead above it. The text view's string
/// stays exactly the source's text, so notes, highlights, find and citation
/// passages anchor as they do everywhere else; the masthead is a subview that
/// scrolls with the text and occupies the container's top inset.
struct ProseReaderPresentation {
    /// The small line above the title: what this text is ("Explainer").
    var kicker: String
    var title: String
    /// One line under the title: length, time, provenance.
    var detail: String
    /// An optional action under the detail line — the way back to the source
    /// an explainer was written about.
    var linkTitle: String?
    var linkAction: (() -> Void)?

    /// What a redraw compares, so a re-render with the same words does no work.
    var fingerprint: String {
        [kicker, title, detail, linkTitle ?? ""].joined(separator: "\u{1F}")
    }
}

/// Type choices for the prose presentation. Sizes are at zoom 1 and scale with
/// the reader's zoom, as the transcript form's system font does.
enum ProseReaderTypography {
    static let bodyPointSize: CGFloat = 17
    static let titlePointSize: CGFloat = 26
    static let lineHeightMultiple: CGFloat = 1.42
    /// Column width in body-font ems: about 70 characters a line, the measure
    /// print has settled on for running text.
    static let columnEms: CGFloat = 38
    static let minimumSideMargin: CGFloat = 24
    static let topPadding: CGFloat = 36
    /// Between the masthead's rule and the first line of the script.
    static let mastheadGap: CGFloat = 28

    static func serif(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let system = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = system.fontDescriptor.withDesign(.serif),
              let font = NSFont(descriptor: descriptor, size: size) else { return system }
        return font
    }

    static func bodyFont(zoomScale: CGFloat) -> NSFont {
        serif(size: bodyPointSize * ArticleReaderZoom.clamped(zoomScale))
    }

    /// The style of a paragraph with words in it: the open line height and a
    /// gap after it, so paragraphs read as paragraphs whatever separates them.
    static func paragraphStyle(bodyFont: NSFont) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = lineHeightMultiple
        style.lineBreakMode = .byWordWrapping
        style.paragraphSpacing = (bodyFont.pointSize * 0.7).rounded()
        return style
    }

    /// The style of a blank line. A writer that separates paragraphs with a
    /// blank line and one that uses a single newline must read the same, so
    /// the gap lives on the paragraph above and the blank line itself takes
    /// almost no height. The text is untouched — only its attributes change —
    /// so every anchor into the string still holds.
    static func blankLineStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 1
        style.maximumLineHeight = 1
        style.lineSpacing = 0
        style.paragraphSpacing = 0
        return style
    }

    /// Applies the two styles paragraph by paragraph.
    static func applyParagraphStyles(to storage: NSTextStorage, bodyFont: NSFont) {
        let text = storage.string as NSString
        guard text.length > 0 else { return }
        let prose = paragraphStyle(bodyFont: bodyFont)
        let blank = blankLineStyle()
        var location = 0
        while location < text.length {
            let range = text.paragraphRange(for: NSRange(location: location, length: 0))
            let isBlank = text.substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            storage.addAttribute(.paragraphStyle, value: isBlank ? blank : prose, range: range)
            location = NSMaxRange(range)
            if range.length == 0 { break }
        }
    }

    static func columnWidth(for bodyFont: NSFont) -> CGFloat {
        (bodyFont.pointSize * columnEms).rounded()
    }
}

/// The block above a prose text: kicker, title, a detail line, an optional
/// link, and a hairline under them. AppKit labels rather than a hosted
/// SwiftUI view, because the text view lays it out by width during its own
/// `layout()` and a wrapping `NSTextField` answers its height for a width
/// synchronously.
final class ProseMastheadView: NSView {
    private let kickerLabel = NSTextField(wrappingLabelWithString: "")
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let linkButton = NSButton(title: "", target: nil, action: nil)
    private let rule = NSBox()
    private var linkAction: (() -> Void)?
    private var fingerprint = ""
    private var fontScale: CGFloat = 1

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for label in [kickerLabel, titleLabel, detailLabel] {
            label.isSelectable = false
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 0
            addSubview(label)
        }
        kickerLabel.textColor = .secondaryLabelColor
        titleLabel.textColor = .labelColor
        detailLabel.textColor = .secondaryLabelColor
        linkButton.isBordered = false
        linkButton.setButtonType(.momentaryChange)
        linkButton.target = self
        linkButton.action = #selector(followLink)
        linkButton.setAccessibilityIdentifier("reader.prose.link")
        addSubview(linkButton)
        rule.boxType = .separator
        addSubview(rule)
        setAccessibilityIdentifier("reader.prose.masthead")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Applies the words and the type scale; returns whether anything changed
    /// so the caller can skip a relayout.
    @discardableResult
    func apply(_ presentation: ProseReaderPresentation, fontScale: CGFloat) -> Bool {
        let changed = presentation.fingerprint != fingerprint
            || ArticleReaderZoom.differs(fontScale, self.fontScale)
        guard changed else { return false }
        fingerprint = presentation.fingerprint
        self.fontScale = fontScale
        linkAction = presentation.linkAction

        let kicker = NSMutableAttributedString(
            string: presentation.kicker.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 11 * fontScale, weight: .semibold),
                .kern: 1.1 * fontScale,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        kickerLabel.attributedStringValue = kicker
        titleLabel.font = ProseReaderTypography.serif(
            size: ProseReaderTypography.titlePointSize * fontScale,
            weight: .medium
        )
        titleLabel.stringValue = presentation.title
        detailLabel.font = NSFont.systemFont(ofSize: 13 * fontScale)
        detailLabel.stringValue = presentation.detail

        if let linkTitle = presentation.linkTitle, presentation.linkAction != nil {
            linkButton.isHidden = false
            linkButton.attributedTitle = NSAttributedString(
                string: linkTitle,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13 * fontScale, weight: .medium),
                    .foregroundColor: NSColor.controlAccentColor,
                ]
            )
            linkButton.toolTip = linkTitle
        } else {
            linkButton.isHidden = true
        }
        return true
    }

    /// Lays the block out for a column width and answers the height it needs.
    func arrange(columnWidth: CGFloat) -> CGFloat {
        let scale = fontScale
        var y: CGFloat = 0
        func place(_ label: NSTextField, gapAbove: CGFloat) {
            y += gapAbove
            label.preferredMaxLayoutWidth = columnWidth
            let bounds = NSRect(x: 0, y: 0, width: columnWidth, height: .greatestFiniteMagnitude)
            let height = label.cell?.cellSize(forBounds: bounds).height ?? label.fittingSize.height
            label.frame = NSRect(x: 0, y: y, width: columnWidth, height: ceil(height))
            y += ceil(height)
        }
        place(kickerLabel, gapAbove: 0)
        place(titleLabel, gapAbove: 8 * scale)
        place(detailLabel, gapAbove: 10 * scale)
        if !linkButton.isHidden {
            y += 10 * scale
            let size = linkButton.fittingSize
            linkButton.frame = NSRect(x: 0, y: y, width: min(columnWidth, ceil(size.width)), height: ceil(size.height))
            y += ceil(size.height)
        }
        y += 20 * scale
        rule.frame = NSRect(x: 0, y: y, width: columnWidth, height: 1)
        y += 1
        return ceil(y)
    }

    @objc private func followLink() {
        linkAction?()
    }
}

/// The inline reader's text view in its prose form: the same find and zoom
/// handling, plus a masthead held in the container's top inset and side
/// insets that centre a measured column.
final class ProseTextView: FindableTextView {
    let masthead = ProseMastheadView(frame: .zero)
    /// The width of the text column at the current body size.
    var columnWidth: CGFloat = 640 {
        didSet { if columnWidth != oldValue { placeMasthead() } }
    }
    override func layout() {
        super.layout()
        placeMasthead()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        placeMasthead()
    }

    /// A text view reports its text, not its subviews, to accessibility; the
    /// masthead's title and its link back to the source are added so VoiceOver
    /// (and the AX-driven verification) can reach them.
    override func accessibilityChildren() -> [Any]? {
        var children = super.accessibilityChildren() ?? []
        if masthead.superview != nil { children.append(masthead) }
        return children
    }

    /// Recomputes the insets and the masthead's frame for the current width.
    /// Cheap to call often: it converges after one pass and only writes the
    /// inset when it differs, because a changed inset invalidates the text.
    func placeMasthead(force: Bool = false) {
        let width = bounds.width
        guard width > 0 else { return }
        if masthead.superview == nil { addSubview(masthead) }
        let column = min(columnWidth, max(200, width - 2 * ProseReaderTypography.minimumSideMargin))
        let side = max(ProseReaderTypography.minimumSideMargin, floor((width - column) / 2))
        let headerHeight = masthead.arrange(columnWidth: column)
        let mastheadFrame = NSRect(x: side, y: ProseReaderTypography.topPadding, width: column, height: headerHeight)
        if masthead.frame != mastheadFrame { masthead.frame = mastheadFrame }
        let inset = NSSize(
            width: side,
            height: ProseReaderTypography.topPadding + headerHeight + ProseReaderTypography.mastheadGap
        )
        if force || textContainerInset != inset {
            textContainerInset = inset
        }
    }
}

struct InlineTextReaderView: NSViewRepresentable {
    @Environment(StudioViewModel.self) private var vm
    let content: String
    /// The source these notes belong to.
    let sourceID: String
    @Binding var selectedText: String
    let findState: ReaderFindState
    let findRevision: Int
    let navigationTarget: SourceSearchBestMatch?
    let zoomScale: CGFloat
    var readerTheme: ReaderColorTheme = .system
    /// Set for text written to be read as an essay — see `ProseReaderPresentation`.
    var prose: ProseReaderPresentation? = nil
    let zoomInAction: () -> Void
    let zoomOutAction: () -> Void
    let resetZoomAction: () -> Void

    private var fontSize: CGFloat {
        NSFont.systemFontSize * ArticleReaderZoom.clamped(zoomScale)
    }

    /// The body font: the system font at the reader's zoom, or the serif
    /// measure in prose form.
    private var bodyFont: NSFont {
        prose == nil
            ? NSFont.systemFont(ofSize: fontSize)
            : ProseReaderTypography.bodyFont(zoomScale: zoomScale)
    }

    /// Prose paragraphs carry their line height on every character, so a
    /// replaced string and a re-zoom both restore it; the transcript form has
    /// no paragraph attributes to keep.
    private func applyProseAttributes(to textView: NSTextView) {
        guard prose != nil, let storage = textView.textStorage else { return }
        let style = ProseReaderTypography.paragraphStyle(bodyFont: bodyFont)
        textView.defaultParagraphStyle = style
        textView.typingAttributes = [
            .font: bodyFont,
            .paragraphStyle: style,
            .foregroundColor: NSColor.labelColor,
        ]
        let fullRange = NSRange(location: 0, length: storage.length)
        guard fullRange.length > 0 else { return }
        storage.beginEditing()
        storage.addAttribute(.font, value: bodyFont, range: fullRange)
        ProseReaderTypography.applyParagraphStyles(to: storage, bodyFont: bodyFont)
        storage.endEditing()
    }

    private func applyMasthead(to textView: ProseTextView) {
        guard let prose else { return }
        let changed = textView.masthead.apply(prose, fontScale: ArticleReaderZoom.clamped(zoomScale))
        let column = ProseReaderTypography.columnWidth(for: bodyFont)
        if changed || textView.columnWidth != column {
            textView.columnWidth = column
            textView.placeMasthead(force: true)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = makeTextView(context: context)
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        scrollView.appearance = readerTheme.nsAppearanceOverride
        return scrollView
    }

    /// The text view in whichever form `prose` asks for. Also used when an
    /// update changes the form — the same reader instance moving from an
    /// explainer to a podcast's raw text, or back — because the masthead and
    /// the insets belong to the prose subclass and cannot be switched off.
    private func makeTextView(context: Context) -> FindableTextView {
        // TextKit 1: avoids a macOS 26 TextKit 2 hang where click selection
        // hit-testing loops forever on the main thread (see ReviewChatComposer).
        let textView: FindableTextView = prose == nil
            ? FindableTextView(usingTextLayoutManager: false)
            : ProseTextView(usingTextLayoutManager: false)
        textView.findState = findState
        textView.zoomInAction = zoomInAction
        textView.zoomOutAction = zoomOutAction
        textView.resetZoomAction = resetZoomAction
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = bodyFont
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.string = content
        applyProseAttributes(to: textView)
        if let proseView = textView as? ProseTextView {
            applyMasthead(to: proseView)
        }
        textView.delegate = context.coordinator
        context.coordinator.callout.attach(toTextView: textView)
        context.coordinator.installNoteHandling(in: textView, vm: vm)
        return textView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard var textView = nsView.documentView as? FindableTextView else { return }
        if (textView is ProseTextView) != (prose != nil) {
            context.coordinator.tearDownNoteHandling()
            context.coordinator.callout.detach()
            textView = makeTextView(context: context)
            nsView.documentView = textView
            context.coordinator.resetNavigation()
            context.coordinator.resetHighlightPainting()
        }
        textView.findState = findState
        textView.zoomInAction = zoomInAction
        textView.zoomOutAction = zoomOutAction
        textView.resetZoomAction = resetZoomAction
        let font = bodyFont
        // A pinch zooms about the words under the pointer. Put back once the
        // masthead, which moves the text, has taken the new size too.
        var pinchAnchor: ReaderPinchTextAnchor?
        if textView.font.map({ ArticleReaderZoom.differs($0.pointSize, font.pointSize) }) ?? true {
            pinchAnchor = ReaderPinchAnchor.textAnchor(in: textView)
            textView.font = font
            applyProseAttributes(to: textView)
        }
        if textView.string != content {
            textView.string = content
            applyProseAttributes(to: textView)
            context.coordinator.resetNavigation()
            // Replacing the string drops every background attribute with it, so
            // the repaint below must not be skipped as a no-op.
            context.coordinator.resetHighlightPainting()
        }
        if let proseView = textView as? ProseTextView {
            applyMasthead(to: proseView)
        }
        pinchAnchor?.restore()
        let desiredAppearance = readerTheme.nsAppearanceOverride
        if nsView.appearance?.name != desiredAppearance?.name {
            nsView.appearance = desiredAppearance
        }
        context.coordinator.parent = self
        context.coordinator.navigateToTargetIfNeeded(in: textView, target: navigationTarget)
        context.coordinator.performFindIfNeeded(in: textView, revision: findRevision, state: findState)
        context.coordinator.repaintHighlightsIfNeeded(vm.highlights(for: sourceID), in: textView)
        context.coordinator.applyPassageTargetIfNeeded(in: textView, vm: vm)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.tearDownNoteHandling()
        coordinator.callout.detach()
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InlineTextReaderView
        private var lastFindRevision = 0
        private var lastNavigationKey: String?
        private let programmaticSelection = ReaderProgrammaticSelection()
        /// The floating "Chat about this" / "Note" bar anchored to the passage.
        let callout = ReaderSelectionCalloutOverlay()
        /// The selection as it stood when the bar appeared, so pressing Note
        /// anchors the passage the reader marked rather than whatever survives
        /// the click.
        private var markedRange: NSRange?
        private var paintedFingerprint: [String] = []
        private var clickRecognizer: NSClickGestureRecognizer?
        private weak var noteTextView: NSTextView?
        private weak var noteViewModel: StudioViewModel?
        /// Which citation passage this reader has already flashed.
        private let passageTracker = ReaderPassageTargetTracker()

        init(parent: InlineTextReaderView) {
            self.parent = parent
        }

        // MARK: Notes

        @MainActor
        func installNoteHandling(in textView: NSTextView, vm: StudioViewModel) {
            noteTextView = textView
            noteViewModel = vm

            callout.onHighlight = { [weak self, weak textView, weak vm] in
                guard let self, let textView, let vm else { return }
                let range = self.markedRange ?? textView.selectedRange()
                guard let anchored = ReaderTextViewHighlightSupport.anchor(
                    in: textView.string,
                    selectedRange: range
                ) else { return }
                // Where the passage is, read before the selection collapses:
                // the card hangs below it.
                let markOnScreen = self.callout.selectionOnScreen()
                self.callout.hide()
                // Collapse to the end of the passage: the mark itself is the
                // feedback now, and the anchor is already computed.
                textView.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
                Task { await vm.highlightReaderSelection(
                    sourceID: self.parent.sourceID,
                    quote: anchored.quote,
                    anchor: anchored.anchor,
                    pdfAnchor: nil,
                    markOnScreen: markOnScreen
                ) }
            }
            // The side chat hangs off the passage, which stays selected, as
            // Chat leaves it.
            callout.onSideChat = { [weak self, weak textView, weak vm] in
                guard let self, let textView, let vm else { return }
                let range = self.markedRange ?? textView.selectedRange()
                let text = textView.string as NSString
                guard range.length > 0, NSMaxRange(range) <= text.length else { return }
                let markOnScreen = self.callout.selectionOnScreen()
                self.callout.hide()
                vm.openReaderSideChat(
                    sourceID: self.parent.sourceID,
                    passage: text.substring(with: range),
                    markOnScreen: markOnScreen,
                    windowNumber: textView.window?.windowNumber
                )
            }

            // Clicking a marked passage opens its note. A click recognizer runs
            // alongside the text view's own selection handling rather than
            // replacing it, so dragging out a new selection still works.
            let recognizer = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
            recognizer.delaysPrimaryMouseButtonEvents = false
            textView.addGestureRecognizer(recognizer)
            clickRecognizer = recognizer

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(revealHighlight(_:)),
                name: .revealReaderHighlight,
                object: nil
            )
        }

        /// A chat citation asked for a passage of this source: scroll to it and
        /// flash it once the text view has a size to scroll in.
        @MainActor
        func applyPassageTargetIfNeeded(in textView: NSTextView, vm: StudioViewModel) {
            guard let target = passageTracker.pending(for: parent.sourceID, in: vm) else { return }
            passageTracker.finish(target, in: vm)
            // Reflowed text has no pages; only the words can be found.
            guard let passage = target.passage else { return }
            ReaderPassageFlash.whenLaidOut(textView) { textView in
                ReaderPassageFlash.flash(passage, in: textView)
            }
        }

        @MainActor
        func tearDownNoteHandling() {
            callout.onHighlight = nil
            callout.onSideChat = nil
            NotificationCenter.default.removeObserver(
                self,
                name: .revealReaderHighlight,
                object: nil
            )
            if let clickRecognizer {
                noteTextView?.removeGestureRecognizer(clickRecognizer)
            }
            clickRecognizer = nil
        }

        @MainActor
        @objc private func revealHighlight(_ notification: Notification) {
            guard let textView = noteTextView,
                  let vm = noteViewModel,
                  let request = notification.object as? ReaderHighlightRevealRequest,
                  request.sourceID == parent.sourceID,
                  let highlight = vm.highlight(
                    id: request.highlightID,
                    sourceID: request.sourceID
                  ) else { return }
            ReaderTextViewHighlightSupport.reveal(highlight, in: textView)
        }

        @MainActor
        @objc private func handleClick(_ recognizer: NSClickGestureRecognizer) {
            guard let textView = noteTextView, let vm = noteViewModel else { return }
            let highlights = vm.highlights(for: parent.sourceID)
            guard !highlights.isEmpty else { return }
            let point = recognizer.location(in: textView)
            guard let hit = ReaderTextViewHighlightSupport.highlight(
                at: point,
                in: textView,
                among: highlights
            ) else { return }
            vm.openReaderHighlight(
                highlightID: hit.id,
                sourceID: parent.sourceID,
                markOnScreen: ReaderTextViewHighlightSupport.frameOnScreen(of: hit, in: textView)
            )
        }

        @MainActor
        func repaintHighlightsIfNeeded(_ highlights: [SourceHighlight], in textView: NSTextView) {
            let fingerprint = highlights.map { "\($0.id)|\($0.color.rawValue)|\($0.updatedAt.timeIntervalSince1970)" }
            guard fingerprint != paintedFingerprint else { return }
            paintedFingerprint = fingerprint
            ReaderTextViewHighlightSupport.paint(highlights, into: textView)
        }

        func resetHighlightPainting() {
            paintedFingerprint = []
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let range = textView.selectedRange()
            DispatchQueue.main.async {
                if self.programmaticSelection.isActive {
                    self.parent.selectedText = ""
                    self.markedRange = nil
                    self.callout.hide()
                    return
                }
                if range.length > 0 {
                    self.parent.selectedText = (textView.string as NSString).substring(with: range)
                    self.markedRange = range
                    self.callout.refresh()
                } else {
                    self.parent.selectedText = ""
                    self.markedRange = nil
                    self.callout.hide()
                }
            }
        }

        @MainActor
        func navigateToTargetIfNeeded(in textView: NSTextView, target: SourceSearchBestMatch?) {
            guard let target,
                  lastNavigationKey != target.presentationKey else { return }
            lastNavigationKey = target.presentationKey
            guard let range = Self.bestRange(in: textView.string, target: target) else { return }
            parent.selectedText = ""
            programmaticSelection.whileActive {
                textView.setSelectedRange(range)
                textView.scrollRangeToVisible(range)
                textView.window?.makeFirstResponder(textView)
            }
        }

        func resetNavigation() {
            lastNavigationKey = nil
        }

        private static func bestRange(in content: String, target: SourceSearchBestMatch) -> NSRange? {
            let haystack = content as NSString
            guard haystack.length > 0 else { return nil }
            let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            let candidates = [
                target.findQuery,
                firstWords(from: target.passage, count: 12),
                firstWords(from: target.excerpt.replacingOccurrences(of: "...", with: " "), count: 12),
            ]
            for candidate in candidates {
                let needle = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !needle.isEmpty else { continue }
                let range = haystack.range(of: needle, options: options)
                if range.location != NSNotFound { return range }
            }
            return nil
        }

        private static func firstWords(from text: String, count: Int) -> String {
            text
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: " ")
                .prefix(count)
                .joined(separator: " ")
        }

        @MainActor
        func performFindIfNeeded(in textView: NSTextView, revision: Int, state: ReaderFindState) {
            guard revision > 0, revision != lastFindRevision else { return }
            lastFindRevision = revision
            // Called inside the SwiftUI render pass — writing selectedText/statusText
            // here is "Modifying state during view update".
            Task { @MainActor [weak self, weak textView] in
                guard let self, let textView else { return }
                parent.selectedText = ""
                ReaderFindPerformer.performTextFind(
                    in: textView,
                    state: state,
                    query: state.query,
                    backwards: state.searchesBackward,
                    programmaticSelection: programmaticSelection
                )
            }
        }
    }
}

// MARK: - EPUB book reader (WKWebView over the book, from its file or its unpacked folder)

/// An EPUB book on the Mac, read as one document: every chapter's file end to
/// end (`EPUBBookDocument`), so the whole book scrolls and Find covers all of
/// it, the way a PDF book reads (`PDFBookReaderView`).
///
/// The chapter under the reading line is the source the panel has selected:
/// reading on into the next chapter moves the selection with the scroll, and a
/// chapter chosen outside the reader — the sidebar, a schedule, Back — scrolls
/// the book to that chapter's saved place. Chapters stay the unit everything
/// is stored in: each keeps its own reading locator, a fraction of its own
/// section, and its notes are anchored in its own text.
struct EPUBBookReaderView: View {
    @Environment(StudioViewModel.self) private var vm
    let initialArticle: StudioArticle
    let chapterArticles: [StudioArticle]
    @Binding var selectedText: String
    let findState: ReaderFindState
    let findRevision: Int
    let zoomScale: CGFloat
    let readerTheme: ReaderColorTheme
    var bookNavigationBridge: ReaderBookNavigationBridge?
    /// The chapter on screen changed, so the panel's selection can follow.
    let chapterChanged: (StudioArticle) -> Void
    let zoomInAction: () -> Void
    let zoomOutAction: () -> Void
    let resetZoomAction: () -> Void

    /// The chapter under the reading line.
    @State private var currentArticle: StudioArticle
    @State private var document: EPUBBookDocument?
    @State private var loadFailed = false
    @State private var loadRevision = 0
    @State private var jump: EPUBBookJump?
    /// Chapters this view told the panel about, in order, that the panel has
    /// yet to echo back through `initialArticle`. Those echoes are not
    /// navigation.
    @State private var reportedChapterIDs: [String] = []
    @State private var progress = EPUBBookProgressWriter()

    init(
        initialArticle: StudioArticle,
        chapterArticles: [StudioArticle],
        selectedText: Binding<String>,
        findState: ReaderFindState,
        findRevision: Int,
        zoomScale: CGFloat,
        readerTheme: ReaderColorTheme,
        bookNavigationBridge: ReaderBookNavigationBridge? = nil,
        chapterChanged: @escaping (StudioArticle) -> Void,
        zoomInAction: @escaping () -> Void,
        zoomOutAction: @escaping () -> Void,
        resetZoomAction: @escaping () -> Void
    ) {
        self.initialArticle = initialArticle
        self.chapterArticles = chapterArticles
        self._selectedText = selectedText
        self.findState = findState
        self.findRevision = findRevision
        self.zoomScale = zoomScale
        self.readerTheme = readerTheme
        self.bookNavigationBridge = bookNavigationBridge
        self.chapterChanged = chapterChanged
        self.zoomInAction = zoomInAction
        self.zoomOutAction = zoomOutAction
        self.resetZoomAction = resetZoomAction
        self._currentArticle = State(initialValue: initialArticle)
    }

    var body: some View {
        Group {
            if let document {
                InlineEPUBReaderView(
                    filePath: document.key,
                    sourceID: currentArticle.id,
                    initialScrollFraction: nil,
                    selectedText: $selectedText,
                    findState: findState,
                    findRevision: findRevision,
                    zoomScale: zoomScale,
                    readerTheme: readerTheme,
                    scrollPositionChanged: { _ in },
                    book: document,
                    bookJump: jump,
                    bookPositionChanged: { report in positionChanged(report, in: document) },
                    bookChapterFocused: { sourceID in focus(sourceID, in: document) },
                    zoomInAction: zoomInAction,
                    zoomOutAction: zoomOutAction,
                    resetZoomAction: resetZoomAction
                )
            } else if loadFailed {
                ContentUnavailableView {
                    Label("Could not load book", systemImage: "book.closed")
                } actions: {
                    Button("Retry") { loadRevision += 1 }
                }
            } else {
                ReaderLoadingView(title: "Loading book…")
            }
        }
        .onChange(of: initialArticle.id) { _, _ in
            externalSelectionChanged()
        }
        .onAppear {
            syncBookNavigationBridge()
        }
        .onDisappear {
            progress.flush()
            bookNavigationBridge?.clear()
        }
        .task(id: "\(bookKey)#\(loadRevision)") {
            await loadBook()
        }
    }

    /// The book and its chapters, so the book is assembled once when it opens
    /// and not again as the selection moves between its chapters — only when
    /// a chapter joins or leaves it.
    private var bookKey: String {
        let chapters = chapterArticles.isEmpty ? [initialArticle] : chapterArticles
        return "\(initialArticle.parentGroup ?? initialArticle.id)|\(chapters.map(\.id).joined(separator: ","))"
    }

    // MARK: Loading

    @MainActor
    private func loadBook() async {
        progress.flush()
        document = nil
        loadFailed = false
        bookNavigationBridge?.clear()

        let candidates = chapterArticles.isEmpty ? [initialArticle] : chapterArticles
        let inputs = candidates.compactMap { article -> EPUBBookDocument.Input? in
            guard let path = article.cachedResolvedLocalPath, EPUBParser.isMarkupChapter(path) else { return nil }
            return EPUBBookDocument.Input(sourceID: article.id, title: article.title, path: path)
        }
        let anchorPath = currentArticle.cachedResolvedLocalPath
        // Reads every chapter file, which may have to come down from iCloud.
        let assembled = await Task.detached(priority: .userInitiated) {
            EPUBBookDocument.assemble(inputs, anchoredAt: anchorPath)?.writingFile()
        }.value
        guard !Task.isCancelled else { return }
        guard let assembled else {
            loadFailed = true
            return
        }

        let opening = assembled.contains(sourceID: currentArticle.id)
            ? resumeArticle(for: currentArticle.id)
            : resumeArticle(for: assembled.chapters[0].sourceID)
        if opening.id != currentArticle.id {
            currentArticle = opening
            reportChapter(opening)
        }
        jump = nextJump(to: opening.id, fraction: savedFraction(of: opening, in: assembled), mode: .resume)
        document = assembled
        syncBookNavigationBridge()
        // Notes from every chapter paint onto the one document.
        for chapter in assembled.chapters {
            await vm.loadReaderHighlightsIfNeeded(for: chapter.sourceID)
        }
    }

    /// The chapter as the panel knows it, with its current reading progress.
    private func resumeArticle(for sourceID: String) -> StudioArticle {
        chapterArticles.first { $0.id == sourceID }
            ?? (initialArticle.id == sourceID ? initialArticle : currentArticle)
    }

    /// How far into its own section a chapter was left, from its saved
    /// locator; the top when it has none, or one for another file.
    private func savedFraction(of article: StudioArticle, in document: EPUBBookDocument) -> Double {
        guard let locator = EPUBReadingPositionLocator(encoded: article.readingPositionLocator),
              let index = document.index(ofSourceID: article.id),
              let relativePath = EPUBKitReaderSupport.relativeChapterPath(for: document.chapters[index].path),
              locator.relativePath == relativePath else { return 0 }
        return min(max(locator.scrollFraction, 0), 1)
    }

    private func nextJump(to sourceID: String, fraction: Double, mode: EPUBBookJump.Mode) -> EPUBBookJump {
        EPUBBookJump(
            position: EPUBBookPosition(sourceID: sourceID, fraction: fraction),
            mode: mode,
            token: (jump?.token ?? 0) + 1
        )
    }

    // MARK: Position

    /// The learner scrolled. Each chapter reported is stored at its own
    /// fraction; one read past is stored at its end. A different chapter
    /// under the reading line also moves the selection.
    private func positionChanged(_ report: EPUBBookPositionReport, in document: EPUBBookDocument) {
        let write = { (sourceID: String, fraction: Double) in
            persist(sourceID: sourceID, fraction: fraction, in: document)
        }
        for passed in report.passedSourceIDs {
            progress.record(passed, fraction: 1, write: write)
        }
        progress.record(report.position.sourceID, fraction: report.position.fraction, write: write)

        let chapter = resumeArticle(for: report.position.sourceID)
        guard chapter.id != currentArticle.id else { return }
        currentArticle = chapter
        reportChapter(chapter)
        syncBookNavigationBridge()
    }

    /// The learner is working in a chapter's text — a selection, a mark, a
    /// note — that is not the one under the reading line.
    private func focus(_ sourceID: String, in document: EPUBBookDocument) {
        guard document.contains(sourceID: sourceID), sourceID != currentArticle.id else { return }
        let chapter = resumeArticle(for: sourceID)
        currentArticle = chapter
        reportChapter(chapter)
        syncBookNavigationBridge()
    }

    private func persist(sourceID: String, fraction: Double, in document: EPUBBookDocument) {
        guard let index = document.index(ofSourceID: sourceID),
              let relativePath = EPUBKitReaderSupport.relativeChapterPath(for: document.chapters[index].path),
              let encoded = EPUBReadingPositionLocator(
                relativePath: relativePath,
                scrollFraction: fraction
              ).encoded else { return }
        vm.updateReadingLocator(for: sourceID, locator: encoded)
    }

    private func reportChapter(_ chapter: StudioArticle) {
        reportedChapterIDs.append(chapter.id)
        chapterChanged(chapter)
    }

    /// `initialArticle` moved: either the panel echoing a chapter this view
    /// reported, which changes nothing on screen, or a chapter chosen outside
    /// the reader, which the book scrolls to, at that chapter's saved place.
    private func externalSelectionChanged() {
        if let echoed = reportedChapterIDs.firstIndex(of: initialArticle.id) {
            // The panel catches up in order; what it echoed and everything
            // reported before it is settled.
            reportedChapterIDs.removeSubrange(...echoed)
            return
        }
        reportedChapterIDs.removeAll()
        guard initialArticle.id != currentArticle.id else { return }
        currentArticle = initialArticle
        selectedText = ""
        guard let document, document.contains(sourceID: initialArticle.id) else { return }
        progress.flush()
        let opening = resumeArticle(for: initialArticle.id)
        jump = nextJump(to: opening.id, fraction: savedFraction(of: opening, in: document), mode: .resume)
        syncBookNavigationBridge()
    }

    /// The Contents menu and the chapter chevrons: a chapter's top.
    private func navigate(to item: BookNavigationItem) {
        guard let document, document.contains(sourceID: item.id) else { return }
        progress.flush()
        jump = nextJump(to: item.id, fraction: 0, mode: .start)
        selectedText = ""
        let article = resumeArticle(for: item.id)
        if article.id != currentArticle.id {
            currentArticle = article
            reportChapter(article)
        }
        syncBookNavigationBridge()
    }

    private func syncBookNavigationBridge() {
        guard let document, document.chapters.count > 1 else {
            bookNavigationBridge?.clear()
            return
        }
        let items = document.chapters.map { chapter in
            BookNavigationItem(id: chapter.sourceID, title: chapter.title, path: chapter.path)
        }
        bookNavigationBridge?.update(
            navigation: BookNavigation(items: items, currentIndex: document.index(ofSourceID: currentArticle.id)),
            navigate: navigate(to:)
        )
    }
}

/// Holds a book's reading positions back for a moment while the learner
/// scrolls: the page reports several times a second, and every stored locator
/// republishes the chapter.
@MainActor
final class EPUBBookProgressWriter {
    private var pending: [String: Double] = [:]
    private var write: ((String, Double) -> Void)?
    private var task: Task<Void, Never>?

    nonisolated init() {}

    func record(_ sourceID: String, fraction: Double, write: @escaping (String, Double) -> Void) {
        pending[sourceID] = fraction
        self.write = write
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        task?.cancel()
        task = nil
        let items = pending
        pending = [:]
        guard let write else { return }
        for (sourceID, fraction) in items {
            write(sourceID, fraction)
        }
    }
}

/// A book's Contents, as a popover off the Reader's ⋯ button, whose menu
/// lists Contents… while the reader has a contents to show. It had a
/// list-and-chevron button of its own on the bar until 2026-10-06 (Quiet
/// chrome, docs/ui-design.md). Picking a chapter, a section or Log as
/// Listened closes it.
extension View {
    func bookContentsPopover(
        isPresented: Binding<Bool>,
        navigation: BookNavigation?,
        navigate: @escaping (BookNavigationItem) -> Void,
        logListened: (([BookNavigationItem]) -> Void)? = nil,
        goToPage: ((Int) -> Void)? = nil
    ) -> some View {
        popover(isPresented: isPresented, arrowEdge: .bottom) {
            if let navigation {
                BookContentsPopover(
                    navigation: navigation,
                    navigate: { item in
                        navigate(item)
                        isPresented.wrappedValue = false
                    },
                    // A chapter's sections are listed only when the reader
                    // can go to them.
                    goToSection: goToPage.map { goToPage in
                        { section in
                            goToPage(section.pageIndex)
                            isPresented.wrappedValue = false
                        }
                    },
                    logListened: logListened.map { action in
                        { items in
                            action(items)
                            isPresented.wrappedValue = false
                        }
                    }
                )
            }
        }
    }
}

private struct BookContentsPopover: View {
    let navigation: BookNavigation
    let navigate: (BookNavigationItem) -> Void
    let goToSection: ((BookNavigationSection) -> Void)?
    let logListened: (([BookNavigationItem]) -> Void)?
    @State private var isSelecting = false
    @State private var selectedItemIDs: Set<String> = []
    /// Chapters whose sections are listed. The chapter being read opens
    /// expanded, so the learner lands on where they are.
    @State private var expandedItemIDs: Set<String>

    init(
        navigation: BookNavigation,
        navigate: @escaping (BookNavigationItem) -> Void,
        goToSection: ((BookNavigationSection) -> Void)?,
        logListened: (([BookNavigationItem]) -> Void)?
    ) {
        self.navigation = navigation
        self.navigate = navigate
        self.goToSection = goToSection
        self.logListened = logListened
        let current = navigation.currentItem.flatMap { $0.sections.isEmpty ? nil : $0.id }
        self._expandedItemIDs = State(initialValue: current.map { [$0] } ?? [])
    }

    private var showsSections: Bool { goToSection != nil && !isSelecting }

    private func visibleSections(of item: BookNavigationItem) -> [BookNavigationSection] {
        showsSections && expandedItemIDs.contains(item.id) ? item.sections : []
    }

    private var popoverHeight: CGFloat {
        let chrome: CGFloat = isSelecting ? 88 : 42
        let sectionRows = navigation.items.reduce(0) { $0 + visibleSections(of: $1).count }
        return min(CGFloat(navigation.items.count) * 38 + CGFloat(sectionRows) * 32 + chrome, 500)
    }

    /// The row the check mark goes on: the current section when it is listed,
    /// otherwise its chapter.
    private func isMarked(_ item: BookNavigationItem) -> Bool {
        guard item.id == navigation.currentItem?.id else { return false }
        guard let currentSectionID = navigation.currentSectionID else { return true }
        return !visibleSections(of: item).contains { $0.id == currentSectionID }
    }

    private var selectedItems: [BookNavigationItem] {
        navigation.items.filter { selectedItemIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Contents")
                    .font(.headline)
                Spacer()
                if logListened != nil {
                    Button(isSelecting ? "Cancel" : "Select") {
                        isSelecting.toggle()
                        selectedItemIDs.removeAll()
                    }
                    .buttonStyle(.hoverWash)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 42)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(navigation.items) { item in
                            Button {
                                if isSelecting {
                                    if selectedItemIDs.contains(item.id) {
                                        selectedItemIDs.remove(item.id)
                                    } else {
                                        selectedItemIDs.insert(item.id)
                                    }
                                } else {
                                    navigate(item)
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Group {
                                        if isSelecting {
                                            Image(systemName: selectedItemIDs.contains(item.id)
                                                ? "checkmark.circle.fill"
                                                : "circle")
                                        } else if isMarked(item) {
                                            Image(systemName: "checkmark")
                                        } else if item.isArchived {
                                            Image(systemName: "archivebox")
                                        }
                                    }
                                    .frame(width: 14)

                                    Text(item.isArchived ? "\(item.title) (archived)" : item.title)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)

                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                // Room for the disclosure button laid over it.
                                .padding(.trailing, showsSections && !item.sections.isEmpty ? 22 : 0)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0))
                            .accessibilityLabel(isSelecting ? "Select \(item.title)" : item.title)
                            .accessibilityValue(
                                isSelecting && selectedItemIDs.contains(item.id) ? "Selected" : ""
                            )
                            .overlay(alignment: .trailing) {
                                if showsSections && !item.sections.isEmpty {
                                    disclosureButton(for: item)
                                }
                            }
                            .contextMenu {
                                if let logListened {
                                    Button {
                                        logListened([item])
                                    } label: {
                                        Label("Log as Listened", systemImage: "headphones")
                                    }
                                }
                            }
                            .id(item.id)

                            ForEach(visibleSections(of: item)) { section in
                                sectionRow(section)
                            }
                        }
                    }
                    .padding(6)
                }
                .onAppear {
                    guard let currentID = navigation.currentSectionID ?? navigation.currentItem?.id else { return }
                    proxy.scrollTo(currentID, anchor: .center)
                }
                .onChange(of: navigation.currentItem?.sections.isEmpty) { _, isEmpty in
                    // Sections are found after the book opens; ones that arrive
                    // while the menu is up open under the chapter being read.
                    guard isEmpty == false, let currentID = navigation.currentItem?.id else { return }
                    expandedItemIDs.insert(currentID)
                }
            }

            if isSelecting, let logListened {
                Divider()
                Button {
                    logListened(selectedItems)
                } label: {
                    Label(
                        selectedItems.count == 1
                            ? "Log as Listened"
                            : "Log \(selectedItems.count) as Listened",
                        systemImage: "headphones"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedItems.isEmpty)
                .padding(8)
            }
        }
        .frame(width: 340, height: max(44, popoverHeight))
    }

    private func disclosureButton(for item: BookNavigationItem) -> some View {
        let isExpanded = expandedItemIDs.contains(item.id)
        return Button {
            if isExpanded {
                expandedItemIDs.remove(item.id)
            } else {
                expandedItemIDs.insert(item.id)
            }
        } label: {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0))
        .padding(.trailing, 4)
        .help(isExpanded ? "Hide sections" : "Show sections")
        .accessibilityLabel(isExpanded ? "Hide sections of \(item.title)" : "Show sections of \(item.title)")
    }

    private func sectionRow(_ section: BookNavigationSection) -> some View {
        let isCurrent = section.id == navigation.currentSectionID
        return Button {
            goToSection?(section)
        } label: {
            HStack(spacing: 8) {
                Group {
                    if isCurrent {
                        Image(systemName: "checkmark")
                    }
                }
                .frame(width: 14)

                Text(section.title)
                    .font(.callout)
                    .foregroundStyle(isCurrent ? .primary : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 0)
            }
            .padding(.leading, 32)
            .padding(.trailing, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0))
        .accessibilityLabel(section.title)
        .accessibilityIdentifier("reader.contents.section")
        .id(section.id)
    }
}

/// Weak proxy to break the WKUserContentController → Coordinator retain cycle.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?
    init(_ delegate: WKScriptMessageHandler) { self.delegate = delegate }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(ucc, didReceive: message)
    }
}

/// Resolves an archived article into its per-device Application Support cache
/// before giving the path to WebKit. This prevents `loadFileURL` from touching
/// an iCloud dataless placeholder on the main actor and makes subsequent reads
/// independent of Optimize Mac Storage.
enum ArchivedArticleFallback {
    /// Studio keeps source bodies out of its startup snapshot. When a rich HTML
    /// archive is missing, resolve the durable SQLite text lazily instead of
    /// mistaking the intentionally-empty in-memory field for lost content.
    static func resolve(
        inMemory: String?,
        loadPersisted: () async -> String?
    ) async -> String? {
        if let inMemory,
           !inMemory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return inMemory
        }
        guard let persisted = await loadPersisted(),
              !persisted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return persisted
    }

    static func shouldUseLiveWebReader(urlString: String, allowed: Bool) -> Bool {
        guard allowed,
              let scheme = URL(string: urlString)?.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }
}

struct ArchivedArticleReaderView: View {
    private static let storage = StorageService()

    let articleID: String
    let canonicalFilePath: String
    let fallbackText: String?
    /// The original web source to show when its rich local archive has not
    /// arrived yet. Local-only and paywalled captures leave this nil/disabled
    /// and retain the durable text fallback instead.
    let liveWebArticle: StudioArticle?
    let allowsLiveWebFallback: Bool
    let initialScrollFraction: Double?
    @Binding var selectedText: String
    let findState: ReaderFindState
    let findRevision: Int
    let navigationTarget: SourceSearchBestMatch?
    let zoomScale: CGFloat
    let readerTheme: ReaderColorTheme
    let scrollPositionChanged: (Double) -> Void
    var readingCompletionReached: (() -> Void)? = nil
    var pageURLChanged: ((URL?) -> Void)? = nil
    var chromeState: ArticleReaderChromeState? = nil
    let zoomInAction: () -> Void
    let zoomOutAction: () -> Void
    let resetZoomAction: () -> Void

    @State private var preparedFilePath: String?
    @State private var failure: ArticleArchiveCache.Failure?
    @State private var persistedFallbackText: String?
    @State private var retryRevision = 0

    private var preparationID: String {
        "\(articleID)|\(canonicalFilePath)|\(retryRevision)"
    }

    var body: some View {
        Group {
            if let preparedFilePath {
                InlineEPUBReaderView(
                    filePath: preparedFilePath,
                    sourceID: articleID,
                    initialScrollFraction: initialScrollFraction,
                    selectedText: $selectedText,
                    findState: findState,
                    findRevision: findRevision,
                    zoomScale: zoomScale,
                    readerTheme: readerTheme,
                    scrollPositionChanged: scrollPositionChanged,
                    readingCompletionReached: readingCompletionReached,
                    pageURLChanged: pageURLChanged,
                    chromeState: chromeState,
                    zoomInAction: zoomInAction,
                    zoomOutAction: zoomOutAction,
                    resetZoomAction: resetZoomAction
                )
            } else if failure != nil,
                      let liveWebArticle,
                      ArchivedArticleFallback.shouldUseLiveWebReader(
                        urlString: liveWebArticle.url,
                        allowed: allowsLiveWebFallback
                      ) {
                // The archive is the preferred offline snapshot, but a stale
                // archive path must not turn an ordinary online article into a
                // processed-text document. WebViewReader still tries any real
                // cached file if the live request itself fails.
                ArticleReaderView(
                    article: liveWebArticle,
                    reviewMode: true,
                    showsSpeechControls: false,
                    showsBrowserToolbar: false,
                    findState: findState,
                    chromeState: chromeState,
                    usesPersistedTextOnLoadFailure: true,
                    selectionChanged: { selectedText = $0 }
                )
            } else if let fallbackText = persistedFallbackText ?? fallbackText,
                      !fallbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      failure != nil {
                InlineTextReaderView(
                    content: fallbackText,
                    sourceID: articleID,
                    selectedText: $selectedText,
                    findState: findState,
                    findRevision: findRevision,
                    navigationTarget: navigationTarget,
                    zoomScale: zoomScale,
                    readerTheme: readerTheme,
                    zoomInAction: zoomInAction,
                    zoomOutAction: zoomOutAction,
                    resetZoomAction: resetZoomAction
                )
            } else if let failure {
                ContentUnavailableView {
                    Label(failure.title, systemImage: failure.symbol)
                } description: {
                    Text(failure.message)
                } actions: {
                    Button("Retry") { retryRevision += 1 }
                }
            } else {
                ReaderLoadingView(title: "Loading article…")
            }
        }
        .task(id: preparationID) {
            preparedFilePath = nil
            failure = nil
            persistedFallbackText = nil
            do {
                let path = try await ArticleArchiveCache.shared.prepare(
                    canonicalHTMLPath: canonicalFilePath,
                    sourceID: articleID
                )
                guard !Task.isCancelled else { return }
                preparedFilePath = path
            } catch is CancellationError {
                // Navigating to another source cancels this view's preparation.
            } catch let cacheFailure as ArticleArchiveCache.Failure {
                guard !Task.isCancelled else { return }
                if let liveWebArticle,
                   ArchivedArticleFallback.shouldUseLiveWebReader(
                    urlString: liveWebArticle.url,
                    allowed: allowsLiveWebFallback
                   ) {
                    failure = cacheFailure
                    return
                }
                persistedFallbackText = await ArchivedArticleFallback.resolve(
                    inMemory: fallbackText,
                    loadPersisted: {
                        await Self.storage.loadSourceContent(articleID)
                    }
                )
                guard !Task.isCancelled else { return }
                failure = cacheFailure
            } catch {
                guard !Task.isCancelled else { return }
                failure = .cacheWriteFailed(error.localizedDescription)
            }
        }
    }
}

struct InlineEPUBReaderView: NSViewRepresentable {
    @Environment(StudioViewModel.self) private var vm
    let filePath: String
    /// The source whose notes belong to the page currently loaded. For a book
    /// this follows the chapter the reader has navigated to.
    let sourceID: String
    let initialScrollFraction: Double?
    @Binding var selectedText: String
    let findState: ReaderFindState
    let findRevision: Int
    let zoomScale: CGFloat
    let readerTheme: ReaderColorTheme
    let scrollPositionChanged: (Double) -> Void
    /// The chapter after this one, when the document is a book chapter. Set, the
    /// page ends with a "Next chapter" footer that continues there; nil on the
    /// last chapter and for every non-book document.
    var nextChapterTitle: String? = nil
    var nextChapterRequested: (() -> Void)? = nil
    /// An EPUB book read as one document (`EPUBBookDocument`). Set, the reader
    /// loads the book instead of `filePath` (which is then the book's `key`),
    /// `sourceID` is the chapter the reader is in, and every chapter's notes
    /// are painted, each in its own section.
    var book: EPUBBookDocument? = nil
    /// The last scroll the host asked of the book; a new `token` is a new ask.
    /// The latest one is applied again whenever the book finishes loading, so
    /// the first one is where the book opens.
    var bookJump: EPUBBookJump? = nil
    /// The chapter under the reading line and how far through it, as the
    /// learner scrolls, with the chapters just read past.
    var bookPositionChanged: ((EPUBBookPositionReport) -> Void)? = nil
    /// The learner selected, marked or opened a note in a chapter other than
    /// the one under the reading line — near a chapter break the lower part
    /// of the window is the next chapter. That chapter becomes the one on
    /// screen, so the card for its note presents.
    var bookChapterFocused: ((String) -> Void)? = nil
    /// Archived-article hosts use this to mark reading complete after a genuine
    /// user scroll reaches the article content's end. Book readers leave it nil.
    var readingCompletionReached: (() -> Void)? = nil
    /// Reports the web view's committed main-frame URL. Archived articles keep
    /// live hyperlinks, so a click can navigate this reader to an external page;
    /// callers use this to point "Open in Browser"/"Copy Link" at the page that
    /// is actually on screen instead of the stored source URL.
    var pageURLChanged: ((URL?) -> Void)? = nil
    /// Host shells pass their chrome state so the toolbar's back/forward buttons
    /// can drive this web view. Archived articles keep live hyperlinks, so a
    /// click can strand the reader on an external page with no way home.
    var chromeState: ArticleReaderChromeState? = nil
    let zoomInAction: () -> Void
    let zoomOutAction: () -> Void
    let resetZoomAction: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        SharedWebKit.applySharedProcessPool(to: config)
        SharedWebKit.disableSystemWritingTools(on: config)
        // A book kept as one file is read from it (`EPUBBookScheme`).
        config.setURLSchemeHandler(EPUBBookScheme.handler, forURLScheme: EPUBBookScheme.name)

        let darkModeScript = WKUserScript(
            source: EPUBReaderStyles.injectionScript(
                theme: readerTheme,
                extendedMediaNormalization: true
            ),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        // Relay text selections back to SwiftUI (user drag/keyboard only).
        let selectionScript = WKUserScript(
            source: ReaderUserSelectionJavaScript.injectionScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        let linkHoverScript = WKUserScript(
            source: ReaderLinkHoverFeedback.injectionScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        let scrollScript = WKUserScript(
            source: ArticleScrollTracking.injectionScript(handlerName: "readingPositionChanged"),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        let mathRenderingScript = WKUserScript(
            source: ArticleMathRendering.injectionScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        let scrollPreservationScript = WKUserScript(
            source: ReaderScrollPreservation.injectionScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        let lightboxScript = WKUserScript(
            source: EPUBReaderStyles.mediaLightboxScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        let chapterFooterScript = WKUserScript(
            source: EPUBReaderStyles.chapterFooterScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        let bookScript = WKUserScript(
            source: EPUBReaderStyles.bookScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(chapterFooterScript)
        config.userContentController.addUserScript(bookScript)
        config.userContentController.addUserScript(darkModeScript)
        config.userContentController.addUserScript(selectionScript)
        config.userContentController.addUserScript(linkHoverScript)
        config.userContentController.addUserScript(scrollScript)
        config.userContentController.addUserScript(mathRenderingScript)
        config.userContentController.addUserScript(scrollPreservationScript)
        config.userContentController.addUserScript(lightboxScript)
        // Injected at document start: a right-click can land before the chapter
        // has finished loading, and the link commands need the destination.
        let contextLinkScript = WKUserScript(
            source: ReaderContextLinkTracking.injectionScript(handlerName: "contextLink"),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(contextLinkScript)
        config.userContentController.add(WeakMessageHandler(context.coordinator), name: "selectionChanged")
        config.userContentController.add(WeakMessageHandler(context.coordinator), name: "readingPositionChanged")
        config.userContentController.add(WeakMessageHandler(context.coordinator), name: "contextLink")
        config.userContentController.add(WeakMessageHandler(context.coordinator), name: "chapterNavigation")
        config.userContentController.add(WeakMessageHandler(context.coordinator), name: "bookPosition")

        let webView = ForeverLMWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.findState = findState
        webView.zoomInAction = zoomInAction
        webView.zoomOutAction = zoomOutAction
        webView.resetZoomAction = resetZoomAction
        Self.applyLinkMenuActions(to: webView, coordinator: context.coordinator)
        ArticleReaderZoom.apply(zoomScale, to: webView)
        webView.setValue(false, forKey: "drawsBackground")
        webView.appearance = readerTheme.nsAppearanceOverride
        applyReaderCanvas(to: webView)
        webView.allowsBackForwardNavigationGestures = true

        // Deferred so a host shell's `chromeState.reset()` for the incoming source
        // can't land after the wiring. The identity-checked binding also prevents
        // a departing reader from disconnecting its replacement.
        if let chromeState {
            Task { @MainActor [webView] in
                chromeState.bindNavigation(to: webView)
            }
        }

        loadFile(into: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        chromeState?.bindNavigation(to: webView)
        if let webView = webView as? ForeverLMWebView {
            webView.findState = findState
            webView.zoomInAction = zoomInAction
            webView.zoomOutAction = zoomOutAction
            webView.resetZoomAction = resetZoomAction
            Self.applyLinkMenuActions(to: webView, coordinator: context.coordinator)
        }
        ArticleReaderZoom.apply(zoomScale, to: webView)
        applyReaderTheme(to: webView)
        // Re-load if the file path changed (user navigated to a different chapter)
        if context.coordinator.loadedFilePath != filePath {
            context.coordinator.restoredPath = nil
            context.coordinator.resetHighlightPainting()
            loadFile(into: webView, coordinator: context.coordinator)
        }
        context.coordinator.performFindIfNeeded(in: webView, revision: findRevision, state: findState)
        context.coordinator.noteViewModel = vm
        context.coordinator.applyHighlightsIfNeeded(to: webView)
        context.coordinator.applyChapterFooterIfNeeded(to: webView)
        context.coordinator.applyBookJumpIfNeeded(to: webView)
        context.coordinator.applyPassageTargetIfNeeded(to: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.tearDownNoteHandling()
        coordinator.parent.chromeState?.unbindNavigation(from: webView)
        coordinator.cancelChapterLoad()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "selectionChanged")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "readingPositionChanged")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "contextLink")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "chapterNavigation")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "bookPosition")
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    /// Hand the reader's own handlers to the link context menu. WebKit answers
    /// its versions back in its web process, where the reader cannot carry them
    /// out — "Download Linked File" never even becomes a `WKDownload`.
    private static func applyLinkMenuActions(to webView: ForeverLMWebView, coordinator: Coordinator) {
        // This reader is a single browsing surface with back/forward chrome, so
        // a link opens here; the coordinator's policy delegate still hands
        // other apps' schemes to macOS.
        webView.openLinkAction = { [weak webView] url in
            webView?.load(URLRequest(url: url))
        }
        webView.openLinkExternallyAction = { url in
            BrowserService.open(url)
        }
        webView.downloadLinkAction = { [weak webView] url in
            guard let webView else { return }
            coordinator.downloadLinkedFile(at: url, in: webView)
        }
    }

    private func loadFile(into webView: WKWebView, coordinator: Coordinator) {
        coordinator.restoredPath = nil
        coordinator.beginChapterLoad(into: webView, filePath: filePath)
    }

    private func applyReaderTheme(to webView: WKWebView) {
        // Archived-article HTML carries its own `prefers-color-scheme` block, which
        // resolves against the web view's appearance rather than the injected
        // attribute — so the override has to be set here for Light to stick.
        webView.appearance = readerTheme.nsAppearanceOverride
        applyReaderCanvas(to: webView)
        let js = """
        document.documentElement.setAttribute('data-flm-reader-theme', '\(readerTheme.rawValue)');
        document.documentElement.style.setProperty('color-scheme', '\(readerTheme.cssColorScheme)');
        """
        webView.evaluateJavaScript(js)
    }

    /// The reader page is transparent by design, so a fixed-dark theme has to
    /// bring its own canvas rather than borrowing the pane's.
    private func applyReaderCanvas(to webView: WKWebView) {
        guard let canvas = readerTheme.opaqueReaderCanvas else {
            webView.layer?.backgroundColor = nil
            return
        }
        webView.wantsLayer = true
        webView.layer?.backgroundColor = canvas.cgColor
    }

    class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        var parent: InlineEPUBReaderView
        /// Held so the message handler can reach the view model; the handler
        /// runs long after `updateNSView` has returned.
        weak var noteViewModel: StudioViewModel?
        private var appliedHighlightFingerprint: [String] = []
        private weak var noteWebView: WKWebView?

        /// Repaints only when the note set actually changed: re-anchoring walks
        /// the whole document, so it must not run on every SwiftUI update.
        /// Nothing is painted into a page still loading — the painter arrives
        /// with the page, and `didFinish` paints what the update skipped.
        @MainActor
        func applyHighlightsIfNeeded(to webView: WKWebView) {
            installRevealObserverIfNeeded(for: webView)
            guard chapterFooterDocumentReady, let vm = noteViewModel else { return }
            let highlights: [SourceHighlight]
            if let book = parent.book {
                highlights = book.chapters.flatMap { vm.highlights(for: $0.sourceID) }
            } else {
                highlights = vm.highlights(for: parent.sourceID)
            }
            let fingerprint = highlights.map { "\($0.id)|\($0.color.rawValue)|\($0.updatedAt.timeIntervalSince1970)" }
            guard fingerprint != appliedHighlightFingerprint else { return }
            appliedHighlightFingerprint = fingerprint
            highlightSourceIDs = Dictionary(highlights.map { ($0.id, $0.sourceID) }, uniquingKeysWith: { first, _ in first })
            ReaderWebHighlightSupport.apply(highlights, to: webView, scopedBySource: parent.book != nil)
        }

        /// Which chapter each painted note belongs to, for a click on one in a
        /// book: the page reports only the note's id.
        private var highlightSourceIDs: [String: String] = [:]

        /// The source a note, selection or citation on the page belongs to: in
        /// a book the chapter the page names, when it is one of the book's.
        private func sourceID(forScope scope: String?) -> String {
            if let scope, let book = parent.book, book.contains(sourceID: scope) { return scope }
            return parent.sourceID
        }

        @MainActor
        private func focusBookChapter(_ sourceID: String) {
            guard parent.book != nil, sourceID != parent.sourceID else { return }
            parent.bookChapterFocused?(sourceID)
        }

        /// Which citation passage this reader has already flashed.
        private let passageTracker = ReaderPassageTargetTracker()

        /// A chat citation asked for a passage of the source on screen: once
        /// the document has loaded, scroll to it and flash it.
        @MainActor
        func applyPassageTargetIfNeeded(to webView: WKWebView) {
            guard chapterFooterDocumentReady, !webView.isLoading,
                  let vm = noteViewModel,
                  let target = passageTracker.pending(for: parent.sourceID, in: vm) else { return }
            passageTracker.finish(target, in: vm)
            guard let passage = target.passage else { return }
            // In a book the passage is searched for in its chapter only, once
            // the jump to that chapter has settled.
            let scope = parent.book != nil ? target.sourceID : nil
            let delay = ReaderPassageFlash.webSettleDelay + (scope == nil ? 0 : 0.4)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak webView] in
                guard let webView else { return }
                if scope != nil {
                    webView.evaluateJavaScript("window.__flmBook && window.__flmBook.release();")
                }
                ReaderPassageFlash.flash(passage, in: webView, scope: scope)
            }
        }

        /// A newly loaded chapter carries no marks, so the next update repaints.
        func resetHighlightPainting() {
            appliedHighlightFingerprint = []
        }

        private func installRevealObserverIfNeeded(for webView: WKWebView) {
            guard noteWebView == nil else { return }
            noteWebView = webView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(revealHighlight(_:)),
                name: .revealReaderHighlight,
                object: nil
            )
        }

        @MainActor
        func tearDownNoteHandling() {
            NotificationCenter.default.removeObserver(
                self,
                name: .revealReaderHighlight,
                object: nil
            )
            noteWebView = nil
        }

        @MainActor
        @objc private func revealHighlight(_ notification: Notification) {
            guard let webView = noteWebView,
                  let request = notification.object as? ReaderHighlightRevealRequest,
                  request.sourceID == parent.sourceID || parent.book?.contains(sourceID: request.sourceID) == true,
                  let highlight = noteViewModel?.highlight(
                    id: request.highlightID,
                    sourceID: request.sourceID
                  ) else { return }
            if parent.book != nil {
                webView.evaluateJavaScript("window.__flmBook && window.__flmBook.release();")
            }
            ReaderWebHighlightSupport.reveal(highlight, in: webView)
        }
        var loadedFilePath: String?
        var restoredPath: String?
        /// The document + next-chapter title the footer was last set for, so a
        /// SwiftUI update that changed neither costs no JavaScript round trip.
        private var appliedChapterFooter: String?
        /// The footer script is injected at document end, so a call before the
        /// document finished loading has nothing to talk to. `didFinish` applies
        /// it; until then updates only record the wish.
        private var chapterFooterDocumentReady = false
        private var chapterLoadTask: Task<Void, Never>?
        private var debounceTask: Task<Void, Never>?
        private var positionDebounceTask: Task<Void, Never>?
        private var lastFindRevision = 0

        init(parent: InlineEPUBReaderView) {
            self.parent = parent
        }

        /// The chapter file read happens off-main (iCloud-evicted files can stall
        /// for seconds), so the load is a cancellable task: navigating to another
        /// chapter mid-read must not load stale content into the web view.
        @MainActor
        func beginChapterLoad(into webView: WKWebView, filePath: String) {
            loadedFilePath = filePath
            chapterFooterDocumentReady = false
            appliedChapterFooter = nil
            appliedBookJumpToken = nil
            chapterLoadTask?.cancel()
            if let book = parent.book {
                // Assembled and written off-main by the host, into the book's
                // `Chapters` folder, which every reference was rewritten to; a
                // book kept as one file is served from it instead.
                chapterLoadTask = nil
                if let fileURL = book.fileURL, !fileURL.isFileURL {
                    webView.load(URLRequest(url: fileURL))
                } else if let fileURL = book.fileURL {
                    webView.loadFileURL(fileURL, allowingReadAccessTo: book.baseURL)
                } else {
                    webView.loadHTMLString(book.html, baseURL: book.baseURL)
                }
                return
            }
            chapterLoadTask = Task { [weak webView] in
                guard let webView else { return }
                await EPUBKitReaderSupport.loadChapter(into: webView, filePath: filePath)
            }
        }

        /// The jump last applied to the book on screen, by token.
        private var appliedBookJumpToken: Int?

        /// Scrolls the book to the host's latest jump once the page can take
        /// it. The page holds the place while the layout settles.
        @MainActor
        func applyBookJumpIfNeeded(to webView: WKWebView) {
            guard parent.book != nil, chapterFooterDocumentReady,
                  let jump = parent.bookJump, jump.token != appliedBookJumpToken,
                  let data = try? JSONSerialization.data(withJSONObject: [
                    jump.position.sourceID,
                    jump.position.fraction,
                    jump.mode.rawValue,
                  ] as [Any]),
                  let arguments = String(data: data, encoding: .utf8) else { return }
            appliedBookJumpToken = jump.token
            let list = arguments.dropFirst().dropLast()
            webView.evaluateJavaScript("window.__flmBook && window.__flmBook.go(\(list));")
        }

        func cancelChapterLoad() {
            chapterLoadTask?.cancel()
            chapterLoadTask = nil
        }

        /// Sets (or removes) the "Next chapter" footer at the end of the loaded
        /// document. Idempotent per document and title; the page-side function
        /// keeps a single footer element and only updates its title.
        @MainActor
        func applyChapterFooterIfNeeded(to webView: WKWebView) {
            guard chapterFooterDocumentReady, let loadedFilePath else { return }
            let title = parent.nextChapterTitle
            let key = "\(loadedFilePath)|\(title ?? "")"
            guard key != appliedChapterFooter else { return }
            appliedChapterFooter = key
            let argument: String
            if let title,
               let data = try? JSONSerialization.data(withJSONObject: [title]),
               let encoded = String(data: data, encoding: .utf8) {
                // A JSON array is the shortest way to a correctly escaped
                // JavaScript string literal.
                argument = "\(encoded)[0]"
            } else {
                argument = "null"
            }
            webView.evaluateJavaScript(
                "window.__flmSetChapterFooter && window.__flmSetChapterFooter(\(argument));"
            )
        }

        /// WebKit asks its UI delegate to create a second web view for links such
        /// as `target="_blank"` and user-initiated `window.open()`. The reader is
        /// intentionally a single browsing surface, so keep arbitrary web links
        /// in this web view (and therefore in its back/forward history) instead
        /// of silently dropping the click.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard navigationAction.targetFrame == nil else { return nil }
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               Self.shouldOpenWithSystem(url) {
                _ = NSWorkspace.shared.open(url)
                return nil
            }
            webView.load(navigationAction.request)
            return nil
        }

        /// Let ordinary HTTP(S), relative, fragment, file, and WebKit-owned URLs
        /// navigate normally. Schemes owned by other macOS apps (mailto:, tel:,
        /// App Store links, and so on) need to leave WebKit or the click fails.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            preferences: WKWebpagePreferences,
            decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
        ) {
            if navigationAction.targetFrame != nil,
               navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               Self.shouldOpenWithSystem(url) {
                _ = NSWorkspace.shared.open(url)
                decisionHandler(.cancel, preferences)
                return
            }
            // A book read as one document never gives way to one of its own
            // chapter files — "Open Link" on a link to a chapter, say. The
            // page scrolls to what the link names instead.
            if let book = parent.book,
               navigationAction.targetFrame?.isMainFrame != false,
               let url = navigationAction.request.url, EPUBBookScheme.isLocalDocument(url),
               url.standardizedFileURL.path != book.documentURL.standardizedFileURL.path,
               let data = try? JSONSerialization.data(withJSONObject: [url.absoluteString]),
               let argument = String(data: data, encoding: .utf8) {
                decisionHandler(.cancel, preferences)
                webView.evaluateJavaScript("window.__flmBook && window.__flmBook.open(\(argument)[0]);")
                return
            }
            // A book's or saved article's link to YouTube never turns the
            // reader into YouTube (`YouTubeContainment`): a video plays in the
            // Reader's player, YouTube's other pages do not open.
            if navigationAction.targetFrame?.isMainFrame != false,
               let url = navigationAction.request.url {
                switch YouTubeContainment.decision(for: url) {
                case .video(let watchURL):
                    decisionHandler(.cancel, preferences)
                    Task { @MainActor in WebPagePolicy.openYouTubeVideo(watchURL) }
                    return
                case .refused:
                    decisionHandler(.cancel, preferences)
                    Task { @MainActor in WebPagePolicy.refuseYouTubePage() }
                    return
                case .notYouTube:
                    break
                }
            }
            decisionHandler(.allow, preferences)
        }

        private static func shouldOpenWithSystem(_ url: URL) -> Bool {
            guard let scheme = url.scheme?.lowercased() else { return false }
            return !["http", "https", "file", "about", "data", "blob", "javascript", EPUBBookScheme.name].contains(scheme)
        }

        /// The URL this page was published at, for resolving site-relative links
        /// in a document being read from disk.
        private var sourceURL: String? {
            let sourceID = parent.sourceID
            return noteViewModel?.activeArticles.first { $0.id == sourceID }?.url
        }

        /// "Download Linked File", which WebKit leaves to the app entirely.
        private lazy var linkDownloader = ReaderLinkDownloader { [weak self] message in
            guard let vm = self?.noteViewModel else { return }
            Task { @MainActor in vm.showToast(message) }
        }

        func downloadLinkedFile(at url: URL, in webView: WKWebView) {
            linkDownloader.start(url, in: webView)
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            // The reader's scripts run in the chapter's main frame only; a
            // frame inside a chapter is the book's, not the reader's
            // (`ScriptMessageSender`).
            guard message.isFrom(.web) else { return }
            switch message.name {
            case "selectionChanged":
                guard let event = ReaderSelectionMessage(body: message.body) else { return }
                debounceTask?.cancel()
                switch event {
                case .selection(let text, let images):
                    let scope = ReaderSelectionMessage.scope(in: message.body)
                    // Pictures go to the view model at once; the debounced
                    // text report below keeps them (see
                    // `updateActiveReaderSelection`).
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let owner = self.sourceID(forScope: scope)
                        if !text.isEmpty || !images.isEmpty { self.focusBookChapter(owner) }
                        self.noteViewModel?.updateActiveReaderSelection(
                            sourceID: owner,
                            text: text,
                            images: images
                        )
                    }
                    debounceTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        guard !Task.isCancelled else { return }
                        self.parent.selectedText = text
                    }
                case .chatRequest(let text, let images):
                    let scope = ReaderSelectionMessage.scope(in: message.body)
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let owner = self.sourceID(forScope: scope)
                        self.focusBookChapter(owner)
                        self.noteViewModel?.updateActiveReaderSelection(
                            sourceID: owner,
                            text: text,
                            images: images
                        )
                        self.parent.selectedText = text
                        ReaderSelectionCallout.requestChat()
                    }
                case .sideChatRequest(let text, let viewportRect):
                    let scope = ReaderSelectionMessage.scope(in: message.body)
                    let webView = message.webView
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let owner = self.sourceID(forScope: scope)
                        self.focusBookChapter(owner)
                        self.noteViewModel?.openReaderSideChat(
                            sourceID: owner,
                            passage: text,
                            markOnScreen: ReaderWebViewportRect.onScreen(viewportRect, in: webView),
                            windowNumber: webView?.window?.windowNumber
                        )
                    }
                case .highlightRequest(let payload):
                    let webView = message.webView
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let owner = self.sourceID(forScope: payload.scope)
                        self.focusBookChapter(owner)
                        await self.noteViewModel?.highlightReaderSelection(
                            sourceID: owner,
                            quote: payload.text,
                            anchor: payload.anchor,
                            pdfAnchor: nil,
                            imageAnchors: payload.imageAnchors,
                            markOnScreen: ReaderWebViewportRect.onScreen(payload.viewportRect, in: webView)
                        )
                    }
                case .openNote(let highlightID, let viewportRect):
                    let webView = message.webView
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let owner = self.highlightSourceIDs[highlightID] ?? self.parent.sourceID
                        self.focusBookChapter(owner)
                        self.noteViewModel?.openReaderHighlight(
                            highlightID: highlightID,
                            sourceID: owner,
                            markOnScreen: ReaderWebViewportRect.onScreen(viewportRect, in: webView)
                        )
                    }
                }
            case "contextLink":
                // A book chapter is read from disk, so a link the publisher
                // wrote as a site-relative path needs the source's own URL to
                // resolve against.
                ReaderContextLinkTracking.apply(message, fallbackBase: sourceURL)
            case "chapterNavigation":
                guard message.body as? String == "next" else { return }
                Task { @MainActor [weak self] in
                    self?.parent.nextChapterRequested?()
                }
            case "bookPosition":
                guard let report = EPUBBookPositionReport(body: message.body) else { return }
                Task { @MainActor [weak self] in
                    guard let self, let book = self.parent.book,
                          book.contains(sourceID: report.position.sourceID) else { return }
                    self.parent.bookPositionChanged?(report)
                }
            case "readingPositionChanged":
                // Archived articles keep live hyperlinks, so this web view can
                // be showing an external page. Only the local document's scroll
                // is reading progress; an external page must not overwrite it.
                guard EPUBBookScheme.isLocalDocument(message.webView?.url) else { return }
                // A book's progress is its chapters', reported over `bookPosition`.
                guard parent.book == nil else { return }
                let fraction: Double?
                let reachedArticleEnd: Bool
                let userInitiated: Bool
                if let body = message.body as? [String: Any],
                   let value = body["fraction"] as? NSNumber {
                    fraction = value.doubleValue
                    reachedArticleEnd = (body["reachedArticleEnd"] as? NSNumber)?.boolValue ?? false
                    userInitiated = (body["userInitiated"] as? NSNumber)?.boolValue ?? false
                } else if let value = message.body as? Double {
                    fraction = value
                    reachedArticleEnd = false
                    userInitiated = false
                } else if let value = message.body as? NSNumber {
                    fraction = value.doubleValue
                    reachedArticleEnd = false
                    userInitiated = false
                } else {
                    fraction = nil
                    reachedArticleEnd = false
                    userInitiated = false
                }
                guard let fraction else { return }
                positionDebounceTask?.cancel()
                positionDebounceTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }
                    self.parent.scrollPositionChanged(fraction)
                    if reachedArticleEnd && userInitiated {
                        self.parent.readingCompletionReached?()
                    }
                }
            default:
                return
            }
        }

        @MainActor
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.chromeState?.setLoading(true, from: webView)
            parent.chromeState?.updateNavigationState(from: webView)
        }

        @MainActor
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            parent.pageURLChanged?(webView.url)
            updateNavigationState(for: webView)
        }

        @MainActor
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.pageURLChanged?(webView.url)
            updateNavigationState(for: webView)
            parent.chromeState?.setLoading(false, from: webView)
            if parent.book == nil {
                restoreInitialScrollIfNeeded(in: webView)
            }
            chapterFooterDocumentReady = true
            appliedChapterFooter = nil
            // A saved article's link can take this view to a live page, and
            // the notes are the saved copy's, not that page's.
            if EPUBBookScheme.isLocalDocument(webView.url) {
                appliedHighlightFingerprint = []
                applyHighlightsIfNeeded(to: webView)
            }
            applyChapterFooterIfNeeded(to: webView)
            applyBookJumpIfNeeded(to: webView)
            applyPassageTargetIfNeeded(to: webView)
        }

        @MainActor
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            updateNavigationState(for: webView)
            parent.chromeState?.setLoading(false, from: webView)
            handleNavigationFailure(for: parent.filePath, error: error)
        }

        @MainActor
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            updateNavigationState(for: webView)
            parent.chromeState?.setLoading(false, from: webView)
            handleNavigationFailure(for: parent.filePath, error: error)
        }

        /// Mirrors WebKit's back/forward list into the host shell's toolbar state.
        @MainActor
        private func updateNavigationState(for webView: WKWebView) {
            parent.chromeState?.updateNavigationState(from: webView)
        }

        @MainActor
        private func handleNavigationFailure(for expectedPath: String, error: Error) {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
            guard loadedFilePath == expectedPath else { return }
            loadedFilePath = nil
            restoredPath = nil
        }

        @MainActor
        private func restoreInitialScrollIfNeeded(in webView: WKWebView) {
            // Only act once per loaded document. On a chapter change the reused
            // WKWebView keeps the previous chapter's scroll offset, so we must
            // always position the page explicitly: to the saved fraction when
            // resuming the opened-on chapter, otherwise to the top.
            guard restoredPath != parent.filePath else { return }
            restoredPath = parent.filePath
            let fraction = parent.initialScrollFraction ?? 0
            let clamped = min(max(fraction, 0), 1)
            let js = """
            setTimeout(function() {
                var doc = document.documentElement;
                var body = document.body;
                var height = Math.max(
                    doc ? doc.scrollHeight : 0,
                    body ? body.scrollHeight : 0
                );
                var viewport = window.innerHeight || (doc ? doc.clientHeight : 0) || 0;
                var maxScroll = Math.max(0, height - viewport);
                window.scrollTo(0, maxScroll * \(clamped));
            }, 80);
            """
            webView.evaluateJavaScript(js)
        }

        @MainActor
        func performFindIfNeeded(in webView: WKWebView, revision: Int, state: ReaderFindState) {
            guard revision > 0, revision != lastFindRevision else { return }
            lastFindRevision = revision
            // Called inside the SwiftUI render pass — writing selectedText/statusText
            // here is "Modifying state during view update".
            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                parent.selectedText = ""
                ReaderFindPerformer.performWebFind(
                    in: webView,
                    state: state,
                    query: state.query,
                    backwards: state.searchesBackward
                )
            }
        }
    }
}

// MARK: - Transcript Reader (podcast / generic text with optional AI cleanup)
