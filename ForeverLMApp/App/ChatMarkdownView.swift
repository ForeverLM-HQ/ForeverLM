import SwiftUI
import Combine
import UniformTypeIdentifiers
import PDFKit
import WebKit
import AppKit

/// What a clicked `foreverlm://source/<id>[?t=<moment>][&page=<n>]` link asks
/// for: the source, for a video, podcast, or recording the moment it should
/// open at, and for a text source the passage the claim rests on — the excerpt
/// the assistant wrote as the link's title, or a `q=` query on a deep link —
/// which the reader scrolls to and flashes, and for a PDF the page the
/// passage sits on, which the reader opens when the words cannot be found.
struct ChatSourceLink: Equatable {
    let sourceID: String
    let seconds: Double?
    let passage: String?
    let page: Int?

    init(sourceID: String, seconds: Double? = nil, passage: String? = nil, page: Int? = nil) {
        self.sourceID = sourceID
        self.seconds = seconds
        self.passage = passage
        self.page = page
    }
}

/// Small, renderer-safe projection of a library source. Chat only needs enough
/// metadata to turn a deterministic `foreverlm://source/<id>` link into a smart
/// link; the full article (and any source content) never enters the WebView.
struct ChatSourceCard: Codable, Equatable {
    /// Roughly twice the largest frame a card is drawn in, so the picture stays
    /// crisp on Retina without making the embedded string big enough to matter.
    private static let thumbnailMaxPixelSize: CGFloat = 144

    let sourceID: String
    let title: String
    let subtitle: String
    let kind: String
    let glyph: String
    let thumbnailURL: String?
    /// True in a notebook's chat for a library source the notebook does not
    /// hold: the page draws its marker as an outline and puts **Add to
    /// Notebook** beside its Sources row (`ChatNotebookCitations`). Nil
    /// everywhere else, and then not encoded.
    var outsideNotebook: Bool? = nil

    /// The card as a notebook's chat shows it: marked when the notebook does
    /// not hold the source, unmarked when it does.
    func inNotebook(_ isMember: Bool) -> ChatSourceCard {
        var card = self
        card.outsideNotebook = isMember ? nil : true
        return card
    }

    /// `collectionTitle` is the human title of the book or course the source
    /// belongs to, resolved by the caller from the library's metadata. A book
    /// chapter's `parentGroup` is the book's stable id — a UUID for anything
    /// imported recently — which tells the reader nothing, so without a title
    /// the card names only the kind.
    init(article: StudioArticle, collectionTitle: String? = nil) {
        sourceID = article.id
        title = article.title
        kind = article.sourceType.rawValue
        glyph = Self.glyph(for: article.sourceType)
        thumbnailURL = SourceArtwork.remoteURL(for: article)?.absoluteString

        var details = [Self.label(for: article.sourceType)]
        switch article.sourceType {
        case .paper:
            if let author = article.displayAuthor {
                details.append(author)
            }
            if let year = article.normalizedPublishedYear,
               year != StudioArticle.unknownPaperYear {
                details.append(year)
            }
        case .book, .course:
            if let collectionTitle = Self.nonempty(collectionTitle) {
                details.append(collectionTitle)
            } else if let parentGroup = article.parentGroup,
                      let readable = StudioViewModel.humanVisibleGroupTitle(parentGroup) {
                details.append(readable)
            } else if let domain = article.displayDomain {
                details.append(domain)
            }
        default:
            if let author = article.displayAuthor {
                details.append(author)
            } else if let domain = article.displayDomain {
                details.append(domain)
            }
        }
        subtitle = details.prefix(3).joined(separator: " · ")
    }

    /// Chat source cards live inside a WebView, so they cannot render the
    /// library's native `SourceThumbnail` directly. Resolve whatever file backs
    /// the source's picture off-main — a paper's first page, an EPUB chapter's
    /// cover, a meeting's stored icon — and embed its small JPEG in the card; a
    /// missing or unavailable file keeps the remote-artwork/letter fallback.
    static func resolved(article: StudioArticle, collectionTitle: String? = nil) async -> ChatSourceCard {
        let card = ChatSourceCard(article: article, collectionTitle: collectionTitle)
        guard let dataURL = await fileThumbnailDataURL(for: article) else {
            return card
        }
        return ChatSourceCard(base: card, thumbnailURL: dataURL)
    }

    private init(base: ChatSourceCard, thumbnailURL: String) {
        sourceID = base.sourceID
        title = base.title
        subtitle = base.subtitle
        kind = base.kind
        glyph = base.glyph
        self.thumbnailURL = thumbnailURL
        outsideNotebook = base.outsideNotebook
    }

    private static func fileThumbnailDataURL(for article: StudioArticle) async -> String? {
        guard let path = await Task.detached(priority: .utility, operation: {
            SourceArtwork.filePath(for: article)
        }).value else { return nil }
        guard let image = await SourceArtwork.thumbnail(
            for: .file(path),
            maxPixelSize: thumbnailMaxPixelSize
        ) else { return nil }
        return SourceArtwork.jpegDataURL(from: image)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func label(for type: StudioSourceType) -> String {
        switch type {
        case .article: return "Article"
        case .paper: return "Paper"
        case .podcast: return "Podcast"
        case .book: return "Book"
        case .course: return "Course"
        case .meeting: return "Meeting"
        case .video: return "Video"
        case .xPost: return "X post"
        case .manual: return "Link"
        case .unclassified: return "Source"
        }
    }

    /// Single-character fallbacks stay crisp at every app zoom level. Sources
    /// with artwork use the actual image in the same frame.
    private static func glyph(for type: StudioSourceType) -> String {
        switch type {
        case .article: return "A"
        case .paper: return "P"
        case .podcast: return "♪"
        case .book: return "B"
        case .course: return "C"
        case .meeting: return "M"
        case .video: return "▶"
        case .xPost: return "X"
        case .manual: return "↗"
        case .unclassified: return "S"
        }
    }
}

/// Remembers how tall each rendered message came out.
///
/// The transcript is lazy and every assistant bubble is a web view, so a row
/// that scrolls out of the stack is torn down — its `@State` height with it —
/// and built again from scratch when it comes back. A rebuilt row used to start
/// at one line and spring open a frame later, once WebKit had laid the markdown
/// out and posted its height back, which shoves everything below it while the
/// scroll is still moving. Starting from the height the row last reported keeps
/// the column still.
@MainActor
enum ChatMarkdownHeightMemory {
    private static var heights: [UUID: CGFloat] = [:]
    private static var order: [UUID] = []
    /// A height is only true for the column width and text size it was measured
    /// at, and every bubble in a transcript shares both. A measurement at new
    /// values retires the whole table rather than tracking staleness per row.
    private static var measuredWidth: CGFloat = 0
    private static var measuredFontSize: CGFloat = 0
    /// Enough for any transcript a lazy stack will hold on to, bounded so a long
    /// session cannot grow this without limit.
    private static let capacity = 400

    static func height(for id: UUID) -> CGFloat? { heights[id] }

    /// The height a row opens at: what it measured last time, or an estimate
    /// from its markdown when nothing has measured it yet. A chat opened from
    /// history lands at its bottom, so every row above the fold is unmeasured;
    /// opening each at one line and letting WebKit spring it to eight hundred
    /// points as it scrolls into view is what read as the transcript jumping.
    static func initialHeight(for id: UUID, markdown: String) -> CGFloat {
        if let remembered = heights[id] { return remembered }
        return estimatedHeight(
            markdown: markdown,
            width: measuredWidth > 0 ? measuredWidth : defaultEstimateWidth,
            fontSize: measuredFontSize > 0 ? measuredFontSize : ChatMarkdownView.baseFontSize
        )
    }

    /// The column width assumed before any bubble has reported one.
    static let defaultEstimateWidth: CGFloat = 640

    /// A rough height for rendered markdown: lines of body text at the chat's
    /// line height, headings and list items as their own lines, plus the
    /// Sources footer a reply with citations ends with. It only has to be near
    /// enough that the measured height, when it lands, moves the column by a
    /// few lines rather than a screen; `ChatTranscriptScrollAnchoring` hides
    /// the remainder for rows above what the learner is looking at.
    static func estimatedHeight(markdown: String, width: CGFloat, fontSize: CGFloat) -> CGFloat {
        let size = max(8, fontSize)
        // Average advance of the system font at body sizes is about half the
        // point size; the column keeps a little padding on each side, and
        // prose stops at the page's 42em measure however wide the column is.
        let charactersPerLine = max(16, floor(max(160, min(width - 24, size * 42)) / (size * 0.5)))
        // chat-render.css: line-height 1.625, Codex's.
        let lineHeight = size * 1.625
        var height: CGFloat = 0
        var blocks = 0
        var inCodeFence = false
        var citations = Set<Substring>()
        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                inCodeFence.toggle()
                blocks += inCodeFence ? 1 : 0
                continue
            }
            guard !line.isEmpty else { continue }
            if inCodeFence {
                height += lineHeight
                continue
            }
            blocks += 1
            if line.hasPrefix("#") {
                // The heading's own line and the air above and below it.
                height += size * 2.9
                continue
            }
            if line == "---" || line == "***" {
                height += size
                continue
            }
            // `[n]` citations become cards in the footer; the marker itself
            // takes no room in the line worth counting.
            var index = line.startIndex
            while let open = line[index...].firstIndex(of: "["),
                  let close = line[open...].firstIndex(of: "]") {
                let inner = line[line.index(after: open)..<close]
                if !inner.isEmpty, inner.count <= 3, inner.allSatisfy(\.isNumber) {
                    citations.insert(inner)
                }
                index = line.index(after: close)
            }
            height += ceil(CGFloat(line.count) / charactersPerLine) * lineHeight
        }
        // Space between blocks: paragraphs, list items and headings all carry
        // some. A heading's larger share is counted with its line above.
        height += CGFloat(max(0, blocks - 1)) * size * 0.62
        if !citations.isEmpty {
            // "Sources" heading, then one two-line card per distinct citation.
            height += size * 2.4 + CGFloat(citations.count) * size * 3.4
        }
        // The bubble's own vertical padding.
        return max(36, ceil(height + size * 1.2))
    }

    static func record(height: CGFloat, width: CGFloat, fontSize: CGFloat, for id: UUID) {
        if width != measuredWidth || fontSize != measuredFontSize {
            heights.removeAll(keepingCapacity: true)
            order.removeAll(keepingCapacity: true)
            measuredWidth = width
            measuredFontSize = fontSize
        }
        if heights.updateValue(height, forKey: id) == nil {
            order.append(id)
            if order.count > capacity {
                heights.removeValue(forKey: order.removeFirst())
            }
        }
    }
}

/// When the transcript was last in motion.
///
/// A streaming answer republishes its text a dozen times a second, and each
/// publish re-renders the bubble's page and reposts its height; the height
/// resizes a row inside the transcript, which sends AppKit through a full
/// layout of the window's hosting view. Doing any of that under a live scroll
/// is what made scrolling a generating chat jitter: the thing being scrolled
/// keeps changing underneath the scroll. So while the transcript is moving, a
/// streaming bubble holds both its new text and its new height, and applies
/// them the moment it stops. Nothing is dropped: the newest text and the newest
/// measurement are what land, and a transcript nobody is scrolling streams at
/// full speed as before.
///
/// Motion is reported by `ChatTranscriptScrollObserver`, which listens to the
/// transcript's scroll view itself, so every way of scrolling counts — wheel
/// and trackpad over any row or margin, momentum, a scroller drag, a keyboard
/// page, an accessibility client — where the earlier wheel-only hook saw only
/// events that landed on an assistant bubble.
@MainActor
enum ChatScrollActivity {
    private static var lastEventAt: ContinuousClock.Instant?

    /// How long after the last scroll event the transcript still counts as
    /// moving. Momentum keeps posting events, so it stays covered; the period
    /// only has to outlast the gap between two of them.
    private static let quietPeriod = Duration.milliseconds(180)

    static func noteScrollEvent() {
        lastEventAt = .now
    }

    /// The scroll view said the gesture is over, so held updates need not wait
    /// out the quiet period.
    static func noteScrollEnded() {
        lastEventAt = nil
    }

    static var isScrolling: Bool {
        guard let lastEventAt else { return false }
        return ContinuousClock.now - lastEventAt < quietPeriod
    }
}

/// Whether a bubble's markdown goes to its page now or waits for the scroll
/// to stop.
///
/// Two kinds of push reach a row. A rewrite of a bubble that is already drawn
/// is the streaming reply, a dozen times a second; under a live scroll that
/// re-layout and the resize it posts are the jitter, so it waits. A row's
/// first paint is different: the row was just built by the lazy transcript
/// for a message scrolled back into view, and its page is blank. Holding that
/// is not smoothing anything — it is a blank bubble for as long as the wheel
/// moves, then every row on screen filling in at once a beat after it stops,
/// which read as the transcript taking a second to load old messages. So a
/// first paint goes at once, scroll or no scroll; the page renders in its own
/// process, and the height it posts lands through the same first-measurement
/// path that has always applied mid-scroll.
enum ChatMarkdownPushPolicy {
    static func holdsPush(isScrolling: Bool, hasPainted: Bool) -> Bool {
        isScrolling && hasPainted
    }
}

/// Keeps what the learner is looking at still when a row above it changes
/// height — what a browser calls scroll anchoring.
///
/// The transcript's scroll view is anchored at its top: when a row above the
/// visible region grows, everything below it moves down by the growth, and
/// the paragraph under the pointer is suddenly somewhere else. Rows above the
/// fold grow all the time: a lazy row rebuilt from history opens at an
/// estimate and is measured by WebKit a frame later, and a row whose source
/// cards or pictures arrive grows again. Each such change asks its transcript
/// to move the visible region by the same amount, in the layout pass that
/// applies the new size, so the content on screen does not move at all.
@MainActor
enum ChatTranscriptScrollAnchoring {
    /// Whether the row `view` draws begins above the visible region of the
    /// scroll view it sits in. Only such a row's growth moves visible content.
    static func rowStartsAboveVisibleRegion(_ view: NSView?) -> Bool {
        guard let view,
              let scrollView = view.enclosingScrollView,
              let document = scrollView.documentView else { return false }
        let row = view.convert(view.bounds, to: document)
        let visible = scrollView.contentView.documentVisibleRect
        return document.isFlipped
            ? row.minY < visible.minY - 0.5
            : row.maxY > visible.maxY + 0.5
    }

    /// Before `view`'s row grows by `growth` (negative when it shrinks): if the
    /// row is above the visible region, arrange for the transcript to scroll by
    /// the same amount once the document has taken its new size.
    static func compensate(for view: NSView?, growth: CGFloat) {
        guard abs(growth) >= 0.5, rowStartsAboveVisibleRegion(view),
              let scrollView = view?.enclosingScrollView else { return }
        ChatTranscriptScrollObserver.ObserverView.observer(for: scrollView)?.deferScroll(by: growth)
    }
}

/// Sits invisibly inside the transcript's scroll view and reports its motion
/// to `ChatScrollActivity`. Live-scroll notifications cover wheel and trackpad
/// gestures including momentum; the clip view's bounds cover everything else
/// that moves the content, scroller drags and programmatic scrolls included.
///
/// It is also the transcript's scroll anchor (`ChatTranscriptScrollAnchoring`):
/// it watches the document view's frame, and a growth registered against it
/// is applied as a scroll in the same layout pass that resizes the document.
struct ChatTranscriptScrollObserver: NSViewRepresentable {
    func makeNSView(context: Context) -> ObserverView {
        ObserverView(frame: .zero)
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {}

    final class ObserverView: NSView {
        private var observations: [NSObjectProtocol] = []
        private weak var observedScrollView: NSScrollView?
        private var lastClipOrigin: CGPoint = .zero
        /// Growth above the visible region that has not been scrolled past
        /// yet. Applied on the document's next frame change, or dropped if
        /// none comes: a growth that never reached the layout has nothing to
        /// compensate.
        private var pendingAdjustment: CGFloat = 0
        /// Where the visible region stood, and how tall the document was, when
        /// the first pending growth was registered. The adjustment is measured
        /// from here rather than from wherever the region is once the document
        /// resizes, because AppKit may already have moved it by then: when a
        /// row above a transcript scrolled to its bottom shrinks, the region is
        /// left hanging past the document's end and the clip view pulls it
        /// back inside as the document takes its new size. Measured from the
        /// moved region, the same shrink was scrolled twice, and the newest
        /// message left the bottom of the screen by the second copy.
        private var pendingAnchorOrigin: CGPoint?
        private var pendingDocumentHeight: CGFloat = 0
        private var pendingAdjustmentExpiry: Task<Void, Never>?

        /// One observer per transcript; the anchoring helper finds it by the
        /// scroll view the row lives in.
        private static let observersByScrollView = NSMapTable<NSScrollView, ObserverView>.weakToWeakObjects()

        static func observer(for scrollView: NSScrollView) -> ObserverView? {
            observersByScrollView.object(forKey: scrollView)
        }

        func deferScroll(by delta: CGFloat) {
            if pendingAnchorOrigin == nil, let scrollView = observedScrollView {
                pendingAnchorOrigin = scrollView.contentView.bounds.origin
                pendingDocumentHeight = scrollView.documentView?.frame.height ?? 0
            }
            pendingAdjustment += delta
            pendingAdjustmentExpiry?.cancel()
            pendingAdjustmentExpiry = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                self?.pendingAdjustment = 0
                self?.pendingAnchorOrigin = nil
            }
        }

        private func applyPendingAdjustment() {
            guard pendingAdjustment != 0,
                  let scrollView = observedScrollView,
                  let document = scrollView.documentView else { return }
            let delta = pendingAdjustment
            let clipView = scrollView.contentView
            var origin = pendingAnchorOrigin ?? clipView.bounds.origin
            pendingAdjustment = 0
            pendingAnchorOrigin = nil
            pendingAdjustmentExpiry?.cancel()
            pendingAdjustmentExpiry = nil
            origin.y += document.isFlipped ? delta : -delta
            let constrained = clipView.constrainBoundsRect(
                NSRect(origin: origin, size: clipView.bounds.size)
            ).origin
            // The transcript's own correction is not the learner scrolling.
            lastClipOrigin = constrained
            // Nothing to do when the clip view's own correction already put the
            // region where the growth says it belongs.
            guard constrained != clipView.bounds.origin else { return }
            clipView.scroll(to: constrained)
            scrollView.reflectScrolledClipView(clipView)
        }

        /// The visible region moved. Between a growth being registered and the
        /// document taking its new size, that happens for one of two reasons:
        /// the document resizing under the region is the clip view keeping it
        /// inside the document, which is not the learner and is already in the
        /// pending adjustment's reckoning; anything else is the learner, and the
        /// pending adjustment follows them.
        private func clipViewBoundsDidChange(_ clipView: NSView) {
            let origin = clipView.bounds.origin
            guard origin != lastClipOrigin else { return }
            let previous = lastClipOrigin
            lastClipOrigin = origin
            if let anchor = pendingAnchorOrigin {
                let documentHeight = observedScrollView?.documentView?.frame.height ?? 0
                if documentHeight != pendingDocumentHeight { return }
                pendingAnchorOrigin = CGPoint(
                    x: anchor.x + origin.x - previous.x,
                    y: anchor.y + origin.y - previous.y
                )
            }
            ChatScrollActivity.noteScrollEvent()
        }

        override var isOpaque: Bool { false }

        /// Never the target of a click or a drop; the content in front of it and
        /// the scroll view behind it own those.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observe(enclosingScrollView)
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            observe(enclosingScrollView)
        }

        private func observe(_ scrollView: NSScrollView?) {
            guard scrollView !== observedScrollView else { return }
            stopObserving()
            if let previous = observedScrollView, Self.observer(for: previous) === self {
                Self.observersByScrollView.removeObject(forKey: previous)
            }
            observedScrollView = scrollView
            guard let scrollView else { return }
            Self.observersByScrollView.setObject(self, forKey: scrollView)
            let center = NotificationCenter.default
            if let document = scrollView.documentView {
                document.postsFrameChangedNotifications = true
                observations.append(center.addObserver(
                    forName: NSView.frameDidChangeNotification, object: document, queue: nil
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.applyPendingAdjustment() }
                })
            }
            let moving: (Notification) -> Void = { _ in
                MainActor.assumeIsolated { ChatScrollActivity.noteScrollEvent() }
            }
            for name in [NSScrollView.willStartLiveScrollNotification, NSScrollView.didLiveScrollNotification] {
                observations.append(center.addObserver(forName: name, object: scrollView, queue: nil, using: moving))
            }
            observations.append(center.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification, object: scrollView, queue: nil
            ) { _ in
                MainActor.assumeIsolated { ChatScrollActivity.noteScrollEnded() }
            })
            // Only a move of the visible region counts. The clip view also posts
            // when the window resizes, and it must not count when the document
            // merely grows under the viewport: that is the streaming row landing
            // its height, and treating it as a scroll would hold the next one.
            scrollView.contentView.postsBoundsChangedNotifications = true
            lastClipOrigin = scrollView.contentView.bounds.origin
            observations.append(center.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: nil
            ) { [weak self] notification in
                guard let clipView = notification.object as? NSView else { return }
                MainActor.assumeIsolated { self?.clipViewBoundsDidChange(clipView) }
            })
        }

        private func stopObserving() {
            for token in observations { NotificationCenter.default.removeObserver(token) }
            observations.removeAll()
        }

        deinit {
            for token in observations { NotificationCenter.default.removeObserver(token) }
        }
    }
}

/// What the learner can do with words selected in a reply: the three
/// actions on the bar the page draws over the selection, and the same three
/// in the reply's context menu. The raw value is the name the page posts.
enum ChatReplySelectionAction: String, CaseIterable {
    /// Drop the passage into this pane's composer as a quote.
    case quote
    /// Ask the tutor to expand on the passage, here, under the reply.
    case moreDetails
    /// Ask about the passage in a small chat that pops over it, without
    /// leaving this chat or starting another.
    case sideChat

    var menuTitle: String {
        switch self {
        case .quote: return "Add to Chat"
        case .moreDetails: return "More Details"
        case .sideChat: return "Ask in Side Chat"
        }
    }

    var symbolName: String {
        switch self {
        case .quote: return "text.quote"
        case .moreDetails: return "text.magnifyingglass"
        case .sideChat: return "rectangle.split.2x1"
        }
    }
}

/// Words selected in a reply, as a popover over them needs them: their box in
/// the reply's view, which the popover hangs from, and the room their screen
/// leaves above and below them, which decides the side it opens on
/// (`ChatReplySideChatPlacement`).
struct ChatSelectionAnchor: Equatable {
    /// In the reply view's points, from its top left.
    let rect: CGRect
    /// Nil when the reply was on no screen as the words were measured.
    let screenRoom: ChatReplySideChatPlacement.ScreenRoom?

    /// `rect`, in `view`'s own coordinates, measured against the visible
    /// frame of the screen `view` is on: its menu bar and Dock are no room.
    @MainActor
    static func screenRoom(around rect: CGRect, in view: NSView?) -> ChatReplySideChatPlacement.ScreenRoom? {
        guard let view, let window = view.window, let screen = window.screen else { return nil }
        let onScreen = window.convertToScreen(view.convert(rect, to: nil))
        let visible = screen.visibleFrame
        return .init(above: visible.maxY - onScreen.maxY, below: onScreen.minY - visible.minY)
    }
}

struct ChatMarkdownView: NSViewRepresentable {
    /// The message this view renders. Its measured height is remembered under
    /// this id so a rebuilt row can start at the right size.
    let identity: UUID
    let markdown: String
    /// What the transcript above this message settled about its citations: the
    /// number each source keeps for the whole conversation, and whose card has
    /// already been listed under an earlier reply. A message rendered without
    /// one numbers from one and lists everything it cites, which is what every
    /// message did before the ledger existed.
    var citationContext = ChatCitationLedger.MessageContext()
    @Binding var height: CGFloat
    let onOpenSource: (ChatSourceLink) -> Void
    let onOpenWebURL: (URL, String?) -> Void
    /// "Open Link in New Window" on a source card or citation, a Cmd-click, or
    /// a link the page opens with target="_blank": the source in a Studio
    /// window of its own. WebKit answers those in the web process and asks the
    /// UI delegate for a window; without this the menu item did nothing
    /// (product owner, 2026-09-21: "this open link in new window is not working for
    /// this book chapter"). Nil falls back to opening beside the chat.
    var onOpenSourceInNewWindow: ((ChatSourceLink) -> Void)? = nil
    /// The Studio windows already open, for "Open in Window 2 — …" on a
    /// source link's menu: the same targets the sidebar offers a source.
    var sourceWindowTargets: (@MainActor () -> [LinkedDocWebView.SourceWindowTarget])? = nil
    /// The learner selected words in this reply and pressed one of the bar's
    /// actions over the selection, or the matching context menu item. The
    /// passage arrives trimmed and never empty; the anchor is where the words
    /// sit in this view's own coordinates and on screen, when the page could
    /// measure them.
    let onSelectionAction: (ChatReplySelectionAction, String, ChatSelectionAnchor?) -> Void
    let sourceCardForToken: @MainActor (String) async -> ChatSourceCard?
    /// Resolves a `foreverlm://image/…` reference to the picture it names, or
    /// nil when this device cannot show it. The same lookup serves the Copy
    /// button, so a copied picture is byte-identical to the one on screen.
    let sourceImageForToken: @MainActor (String) async -> ChatSourceImage?
    /// Add under a slide the chat showed: imports the paper "Extract papers"
    /// read off that slide, by its candidate id. The picture is looked up
    /// again once it returns, so the row turns into a link to the new source.
    /// Nil hides the button.
    var addSlideCitedPaper: (@MainActor (String) async -> Void)? = nil
    /// What decides the citation cards' notebook mark — the chat's notebook
    /// and its membership revision (`ChatNotebookCitations.revision`); empty
    /// outside a notebook's chat. When it changes the page asks for its cards
    /// again, so a source added to the notebook loses its mark in every row.
    var citationScopeKey = ""
    /// Add to Notebook beside a Sources row the notebook does not hold: adds
    /// the source the token names to the chat's notebook. Nil offers none.
    var addSourceToNotebook: (@MainActor (String) async -> Void)? = nil
    /// Redraw With on a right-clicked picture from the image store: draws
    /// the version named (by its id) again with the model chosen, and
    /// returns once the redraw has landed or failed. Nil offers no menu lines
    /// for pictures.
    var redrawPicture: (@MainActor (String, ImageGenerationModel) async -> Void)? = nil
    /// Whether this row's measured height goes into `ChatMarkdownHeightMemory`.
    /// The memory holds one column width for the whole transcript and retires
    /// every height when a row reports at another, so a reply drawn at some
    /// other width, such as the side chat's answer in its popover, must not
    /// record: it would make every transcript row open at an estimate again.
    var remembersHeight = true
    @Environment(\.uiZoomScale) private var uiZoomScale

    /// Base size for chat body text at zoom scale 1. The web view holds rendered
    /// markdown, which SwiftUI's dynamicTypeSize zoom can't reach, so it follows
    /// the app-wide zoom through an explicit body font-size instead. Native chat
    /// text (user bubbles, the composer) scales off the same constant so both
    /// sides of the transcript stay the same size at every zoom step.
    static let baseFontSize: CGFloat = 13

    private var scaledFontSize: CGFloat {
        (Self.baseFontSize * uiZoomScale).rounded()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            identity: identity,
            citationContext: citationContext,
            height: $height,
            onOpenSource: onOpenSource,
            onOpenWebURL: onOpenWebURL,
            onOpenSourceInNewWindow: onOpenSourceInNewWindow,
            sourceWindowTargets: sourceWindowTargets,
            onSelectionAction: onSelectionAction,
            sourceCardForToken: sourceCardForToken,
            sourceImageForToken: sourceImageForToken,
            addSlideCitedPaper: addSlideCitedPaper,
            redrawPicture: redrawPicture,
            remembersHeight: remembersHeight
        )
    }

    /// Every channel the page posts on. One list, so a pooled web view is
    /// rewired for its next row with exactly the handlers a fresh one gets.
    private static let scriptMessageNames = [
        "height", "sourceCards", "sourceImages", "copySourceImage", "zoomSourceImage", "addSlideCitedPaper",
        "addSourceToNotebook",
        "openSource", "webLinks", "selectionAction", contextLinkMessageName, contextPictureMessageName,
    ]

    /// The channel the page reports the link under the pointer on when a
    /// context menu is raised, so `willOpenMenu` can retarget WebKit's link
    /// commands — which the web process would otherwise answer, where a
    /// foreverlm:// address means nothing — at the source they name.
    private static let contextLinkMessageName = "contextLink"

    /// The channel the page reports the picture under the pointer on when a
    /// context menu is raised — its `foreverlm://image/…` token, or an empty
    /// string over anything else — so `willOpenMenu` can say what made a
    /// picture from the image store and offer to draw it again.
    private static let contextPictureMessageName = "contextPicture"

    /// Reports the picture under a right-click, in the capture phase so it
    /// lands before WebKit builds its menu, as the link report does.
    private static let contextPictureScript = """
        (function() {
            if (window.__foreverlmContextPictureInstalled) { return; }
            window.__foreverlmContextPictureInstalled = true;
            document.addEventListener('contextmenu', function(event) {
                var node = event.target;
                var figure = node && node.closest ? node.closest('figure.source-image-figure') : null;
                var token = figure ? (figure.dataset.sourceImage || '') : '';
                window.webkit.messageHandlers.\(contextPictureMessageName).postMessage(token);
            }, true);
        })();
        """

    /// The tokens of every picture the page shows.
    fileprivate static let pictureTokensScript =
        "Array.from(document.querySelectorAll('figure.source-image-figure')).map(function(f) { return f.dataset.sourceImage || ''; })"

    /// Creating a WKWebView is one of the most expensive main-thread operations
    /// in the app: WebKit launches a web process for the new page and registers
    /// the user's entire installed-font library with it, which takes hundreds of
    /// milliseconds on font-heavy systems. Switching chats replaces every message
    /// row at once, so paying that per assistant message beachballs the app.
    /// Dismantled message web views are parked here with the markdown template
    /// still loaded, and the next message row only has to push new markdown.
    @MainActor private static var reusableWebViews: [ChatMarkdownWebView] = []
    /// Parked message web views, kept loaded so a row scrolled back into view
    /// reuses one instead of launching a web process. Sized to comfortably
    /// exceed a screenful of bubbles plus the churn of a fast scroll: creating a
    /// WKWebView mid-scroll is the hundreds-of-millisecond stall that dropped
    /// frames and made a long transcript stutter, so the pool has to outlast the
    /// scroll, not just the visible rows.
    private static let reusePoolCapacity = 16
    /// How many parked views the pool keeps ready while a transcript is open.
    /// The pool used to fill only with views the transcript had discarded, so
    /// the first scroll back through a chat found it empty and paid a template
    /// load — 80 to 200 ms in the web process before the page could draw — for
    /// every row that entered. Spares are made while the user reads, one at a
    /// time and never during a scroll, so a row scrolled in finds a loaded page.
    private static let reusePoolWarmTarget = 6
    private static var reusePoolWarmTask: Task<Void, Never>?

    /// Parks a fresh, loading web view whenever a row takes one and fewer than
    /// the warm target remain. A view goes into the pool as soon as it exists;
    /// a row that takes it before its template has finished paints from
    /// `didFinish`, which every row already handles.
    @MainActor private static func topUpReusePool() {
        guard reusePoolWarmTask == nil, reusableWebViews.count < reusePoolWarmTarget else { return }
        reusePoolWarmTask = Task { @MainActor in
            defer { reusePoolWarmTask = nil }
            while reusableWebViews.count < reusePoolWarmTarget {
                // Never make one under a live scroll: the init is on the main
                // thread and the template load competes with entering rows for
                // the web process. Wait it out, then space them out so a chat
                // opening pays a few milliseconds a turn, not a burst.
                while ChatScrollActivity.isScrolling {
                    try? await Task.sleep(for: .milliseconds(120))
                    guard !Task.isCancelled else { return }
                }
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, reusableWebViews.count < reusePoolWarmTarget else { return }
                reusableWebViews.insert(makeTemplateWebView(), at: 0)
            }
        }
    }

    /// A message web view with the chat page loading, its handlers still to be
    /// attached by the row that takes it.
    @MainActor private static func makeTemplateWebView(
        contentController: WKUserContentController = WKUserContentController()
    ) -> ChatMarkdownWebView {
        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        SharedWebKit.applySharedProcessPool(to: config)
        SharedWebKit.disableSystemWritingTools(on: config)
        // Chat markdown renders system fonts only. Opting out of user-installed
        // fonts lets WebKit skip enumerating and registering the user's whole
        // font library for each new web process — the dominant cost of the
        // chat-switch main-thread stalls captured by UIResponsivenessMonitor.
        if config.preferences.responds(to: Selector(("_setShouldAllowUserInstalledFonts:"))) {
            config.preferences.setValue(false, forKey: "shouldAllowUserInstalledFonts")
        }
        contentController.addUserScript(Self.configurationScript)
        contentController.addUserScript(
            WKUserScript(
                source: ReaderContextLinkTracking.injectionScript(handlerName: Self.contextLinkMessageName),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
        contentController.addUserScript(
            WKUserScript(source: Self.contextPictureScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )

        let webView = ChatMarkdownWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        // The first paint happens in didFinish, which pushes the latest markdown
        // and font size once the page's scripts exist.
        Self.loadTemplate(into: webView)
        return webView
    }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.lastMarkdown = markdown
        context.coordinator.lastCitationContext = citationContext
        context.coordinator.lastFontSize = scaledFontSize

        if let webView = Self.reusableWebViews.popLast() {
            context.coordinator.webView = webView
            for name in Self.scriptMessageNames {
                webView.configuration.userContentController.add(context.coordinator, name: name)
            }
            webView.navigationDelegate = context.coordinator
            webView.uiDelegate = context.coordinator
            webView.sourceLinkActions = context.coordinator.sourceLinkActions()
            webView.redrawPicture = context.coordinator.redrawPicture
            webView.evaluateJavaScript("document.body.style.fontSize = '\(scaledFontSize)px';")
            // The page is loaded, so the message renders about 30 ms after this
            // push and the row takes its measured height. A parked view whose
            // template is still loading drops this call and paints from
            // didFinish instead.
            context.coordinator.pushMarkdown(into: webView)
            Self.topUpReusePool()
            return webView
        }
        Self.topUpReusePool()

        let contentController = WKUserContentController()
        for name in Self.scriptMessageNames {
            contentController.add(context.coordinator, name: name)
        }

        let webView = Self.makeTemplateWebView(contentController: contentController)
        context.coordinator.webView = webView
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.sourceLinkActions = context.coordinator.sourceLinkActions()
        webView.redrawPicture = context.coordinator.redrawPicture
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.webView = webView
        context.coordinator.height = $height
        context.coordinator.onOpenSource = onOpenSource
        context.coordinator.onOpenWebURL = onOpenWebURL
        context.coordinator.onOpenSourceInNewWindow = onOpenSourceInNewWindow
        context.coordinator.sourceWindowTargets = sourceWindowTargets
        context.coordinator.onSelectionAction = onSelectionAction
        context.coordinator.sourceCardForToken = sourceCardForToken
        context.coordinator.sourceImageForToken = sourceImageForToken
        context.coordinator.addSlideCitedPaper = addSlideCitedPaper
        context.coordinator.addSourceToNotebook = addSourceToNotebook
        context.coordinator.redrawPicture = redrawPicture
        (webView as? ChatMarkdownWebView)?.redrawPicture = redrawPicture
        if context.coordinator.lastFontSize != scaledFontSize {
            context.coordinator.lastFontSize = scaledFontSize
            // The ResizeObserver on #content reposts the height after the reflow.
            webView.evaluateJavaScript("document.body.style.fontSize = '\(scaledFontSize)px';")
        }
        if context.coordinator.lastCitationScopeKey != citationScopeKey {
            let painted = context.coordinator.lastCitationScopeKey != nil
            context.coordinator.lastCitationScopeKey = citationScopeKey
            // The notebook's sources changed under a row already drawn: its
            // cards are asked for again, marked as the notebook holds them now.
            if painted, !context.coordinator.lastMarkdown.isEmpty {
                context.coordinator.refreshSourceCards(in: webView)
            }
        }
        guard context.coordinator.lastMarkdown != markdown
            || context.coordinator.lastCitationContext != citationContext else { return }
        context.coordinator.lastMarkdown = markdown
        context.coordinator.lastCitationContext = citationContext
        context.coordinator.pushMarkdown(into: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.cancelPendingUpdates()
        for name in scriptMessageNames {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: name)
        }
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        if let reusable = webView as? ChatMarkdownWebView, reusableWebViews.count < reusePoolCapacity {
            reusable.removeFromSuperview()
            reusable.forgetSourceCards()
            reusable.forgetPictures()
            reusable.sourceLinkActions = nil
            reusable.redrawPicture = nil
            // Keep the loaded template page (and its web process) alive so the
            // next message row can reuse it without a process launch; just drop
            // the old message content and its source metadata projection.
            reusable.evaluateJavaScript(
                "window.resetSourceCards(); window.resetSourceImages(); "
                    + "window.setCitationContext(null); window.setMarkdown('');"
            )
            reusableWebViews.append(reusable)
        } else {
            webView.loadHTMLString("", baseURL: nil)
        }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        let identity: UUID
        var height: Binding<CGFloat>
        var onOpenSource: (ChatSourceLink) -> Void
        var onOpenWebURL: (URL, String?) -> Void
        var onOpenSourceInNewWindow: ((ChatSourceLink) -> Void)?
        var sourceWindowTargets: (@MainActor () -> [LinkedDocWebView.SourceWindowTarget])?
        var onSelectionAction: (ChatReplySelectionAction, String, ChatSelectionAnchor?) -> Void
        var sourceCardForToken: @MainActor (String) async -> ChatSourceCard?
        var sourceImageForToken: @MainActor (String) async -> ChatSourceImage?
        var addSlideCitedPaper: (@MainActor (String) async -> Void)?
        var addSourceToNotebook: (@MainActor (String) async -> Void)?
        /// `ChatMarkdownView.citationScopeKey` as this row last drew it; nil
        /// before its first update.
        var lastCitationScopeKey: String?
        var redrawPicture: (@MainActor (String, ImageGenerationModel) async -> Void)?
        /// `ChatMarkdownView.remembersHeight`, fixed for this row.
        let remembersHeight: Bool
        var lastMarkdown = ""
        var lastCitationContext = ChatCitationLedger.MessageContext()
        var lastFontSize: CGFloat = ChatMarkdownView.baseFontSize
        /// The web view this coordinator drives, for finding the row's place in
        /// the transcript when its height lands.
        weak var webView: WKWebView?
        private var pendingHeight: CGFloat?
        private var pendingWidth: CGFloat = 0
        /// Whether a measurement has landed since this row was built. Until one
        /// has, the row stands at a remembered or estimated height.
        private var hasAppliedHeight = false
        private var heightUpdateTask: Task<Void, Never>?
        private var markdownPushTask: Task<Void, Never>?
        /// Whether this row's page has been handed markdown to draw. False for
        /// a row the transcript just built, and again for a page that just
        /// loaded: those paint at once (`ChatMarkdownPushPolicy`).
        private var hasPaintedMarkdown = false
        private var sourceCardResolutionGeneration = 0
        /// Hears that a picture was drawn again, so this row's page shows
        /// the redraw where it showed the picture.
        private var redrawObserver: NSObjectProtocol?

        init(
            identity: UUID,
            citationContext: ChatCitationLedger.MessageContext,
            height: Binding<CGFloat>,
            onOpenSource: @escaping (ChatSourceLink) -> Void,
            onOpenWebURL: @escaping (URL, String?) -> Void,
            onOpenSourceInNewWindow: ((ChatSourceLink) -> Void)? = nil,
            sourceWindowTargets: (@MainActor () -> [LinkedDocWebView.SourceWindowTarget])? = nil,
            onSelectionAction: @escaping (ChatReplySelectionAction, String, ChatSelectionAnchor?) -> Void,
            sourceCardForToken: @escaping @MainActor (String) async -> ChatSourceCard?,
            sourceImageForToken: @escaping @MainActor (String) async -> ChatSourceImage?,
            addSlideCitedPaper: (@MainActor (String) async -> Void)? = nil,
            redrawPicture: (@MainActor (String, ImageGenerationModel) async -> Void)? = nil,
            remembersHeight: Bool = true
        ) {
            self.identity = identity
            self.remembersHeight = remembersHeight
            self.lastCitationContext = citationContext
            self.height = height
            self.onOpenSourceInNewWindow = onOpenSourceInNewWindow
            self.sourceWindowTargets = sourceWindowTargets
            self.onOpenSource = onOpenSource
            self.onOpenWebURL = onOpenWebURL
            self.onSelectionAction = onSelectionAction
            self.sourceCardForToken = sourceCardForToken
            self.sourceImageForToken = sourceImageForToken
            self.addSlideCitedPaper = addSlideCitedPaper
            self.redrawPicture = redrawPicture
            super.init()
            redrawObserver = NotificationCenter.default.addObserver(
                forName: .generatedImageRedrawn, object: nil, queue: .main
            ) { [weak self] note in
                let replaced = (note.userInfo?[GeneratedImageRedraw.replacedKey] as? [String]) ?? []
                self?.showRedraws(of: Set(replaced.map { $0.lowercased() }))
            }
        }

        /// The box the page measured around the selected words, in CSS pixels
        /// of a page drawn at scale one — which are this view's points. Nil
        /// when the page sent none, or a box with nothing in it.
        static func selectionRect(in body: [String: Any]) -> CGRect? {
            guard let box = body["rect"] as? [String: Any],
                  let x = (box["x"] as? NSNumber)?.doubleValue,
                  let y = (box["y"] as? NSNumber)?.doubleValue,
                  let width = (box["width"] as? NSNumber)?.doubleValue,
                  let height = (box["height"] as? NSNumber)?.doubleValue,
                  [x, y, width, height].allSatisfy(\.isFinite),
                  width > 0 || height > 0 else { return nil }
            return CGRect(x: x, y: y, width: width, height: height)
        }

        func cancelPendingUpdates() {
            heightUpdateTask?.cancel()
            heightUpdateTask = nil
            pendingHeight = nil
            markdownPushTask?.cancel()
            markdownPushTask = nil
            sourceCardResolutionGeneration &+= 1
        }

        deinit {
            heightUpdateTask?.cancel()
            markdownPushTask?.cancel()
            if let redrawObserver { NotificationCenter.default.removeObserver(redrawObserver) }
        }

        /// Hands the page the redraw of every picture it shows that `ids`
        /// names; the lookup, its cache cleared by the redraw, now reads the
        /// version shown in the old one's place.
        private func showRedraws(of ids: Set<String>) {
            guard !ids.isEmpty else { return }
            let resolver = sourceImageForToken
            let webView = self.webView
            Task { @MainActor [weak webView] in
                guard let webView,
                      let tokens = try? await webView.evaluateJavaScript(ChatMarkdownView.pictureTokensScript) as? [String] else { return }
                let redrawn = tokens.filter { token in
                    GeneratedImageReference(urlString: token).map { ids.contains($0.id) } ?? false
                }
                guard !redrawn.isEmpty else { return }
                let images = await ChatMarkdownView.sourceImageLookup(tokens: redrawn, sourceImageForToken: resolver)
                (webView as? ChatMarkdownWebView)?.rememberPictures(images)
                guard let json = ChatMarkdownView.sourceImageJSON(images) else { return }
                _ = try? await webView.evaluateJavaScript("window.setSourceImages(\(json));")
            }
        }

        /// Sends `lastMarkdown` to the page — now, unless the transcript is
        /// scrolling. A streaming bubble is rewritten a dozen times a second, and
        /// each rewrite has the web process re-lay out the whole message and the
        /// app commit its new layers, then reposts a height that resizes the row.
        /// Under a live scroll that is the jitter, so the push waits for the
        /// scroll to stop. One waiter is enough: it reads `lastMarkdown` when it
        /// lands, so the text that arrives is the newest, never a stale frame.
        func pushMarkdown(into webView: WKWebView) {
            let holds = ChatMarkdownPushPolicy.holdsPush(
                isScrolling: ChatScrollActivity.isScrolling,
                hasPainted: hasPaintedMarkdown
            )
            guard holds else {
                markdownPushTask?.cancel()
                markdownPushTask = nil
                hasPaintedMarkdown = true
                webView.evaluateJavaScript(ChatMarkdownView.markdownPushScript(
                    citationContext: lastCitationContext,
                    markdown: lastMarkdown
                ))
                return
            }
            guard markdownPushTask == nil else { return }
            markdownPushTask = Task { @MainActor [weak self, weak webView] in
                while ChatScrollActivity.isScrolling {
                    try? await Task.sleep(for: .milliseconds(60))
                    guard !Task.isCancelled else { return }
                }
                guard let self, let webView else { return }
                self.markdownPushTask = nil
                _ = try? await webView.evaluateJavaScript(ChatMarkdownView.markdownPushScript(
                    citationContext: self.lastCitationContext,
                    markdown: self.lastMarkdown
                ))
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == ChatMarkdownView.contextLinkMessageName {
                // The DOM saw the right-click before WebKit built the menu;
                // the web view remembers the link so `willOpenMenu` can act on it.
                guard let body = message.body as? [String: Any],
                      let webView = message.webView as? ChatMarkdownWebView else { return }
                let url = ReaderContextLinkTracking.resolvedURL(
                    href: (body["href"] as? String) ?? "",
                    raw: (body["raw"] as? String) ?? "",
                    fallbackBase: nil
                )
                webView.noteContextLink(url: url)
                return
            }
            if message.name == ChatMarkdownView.contextPictureMessageName {
                (message.webView as? ChatMarkdownWebView)?.noteContextPicture(token: message.body as? String)
                return
            }
            if message.name == "sourceCards" {
                resolveSourceCards(for: message)
                return
            }
            if message.name == "sourceImages" {
                resolveSourceImages(for: message)
                return
            }
            if message.name == "copySourceImage" {
                copySourceImage(for: message)
                return
            }
            if message.name == "zoomSourceImage" {
                zoomSourceImage(for: message)
                return
            }
            if message.name == "addSlideCitedPaper" {
                addSlideCitedPaper(for: message)
                return
            }
            if message.name == "addSourceToNotebook" {
                addSourceToNotebook(for: message)
                return
            }
            if message.name == "selectionAction" {
                // The page names the action and hands over the words; an
                // action this build does not know is dropped, not guessed at.
                guard let body = message.body as? [String: Any],
                      let action = (body["action"] as? String).flatMap(ChatReplySelectionAction.init(rawValue:)),
                      let text = (body["text"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { return }
                let anchor = Self.selectionRect(in: body).map { rect in
                    ChatSelectionAnchor(
                        rect: rect,
                        screenRoom: ChatSelectionAnchor.screenRoom(around: rect, in: message.webView)
                    )
                }
                onSelectionAction(action, text, anchor)
                return
            }
            if message.name == "openSource" {
                // The page hands over the token it parsed and the moment the
                // link carried; the seconds arrive as a number, or null for a
                // link that names none.
                guard let body = message.body as? [String: Any],
                      let token = (body["token"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !token.isEmpty else { return }
                let seconds = (body["seconds"] as? NSNumber)?.doubleValue
                let passage = (body["passage"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let page = (body["page"] as? NSNumber)?.intValue
                onOpenSource(ChatSourceLink(
                    sourceID: token,
                    seconds: seconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
                    passage: passage?.isEmpty == false ? passage : nil,
                    page: page.flatMap { $0 >= 1 ? $0 : nil }
                ))
                return
            }
            if message.name == "webLinks",
               let body = message.body as? [String: Any],
               let rawURL = body["url"] as? String,
               let url = URL(string: rawURL),
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                let title = (body["title"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                onOpenWebURL(url, title?.isEmpty == false ? title : nil)
                return
            }
            guard message.name == "height" else { return }
            let rawHeight: Double?
            if let value = message.body as? Double {
                rawHeight = value
            } else if let value = message.body as? NSNumber {
                rawHeight = value.doubleValue
            } else {
                rawHeight = nil
            }
            guard let rawHeight else { return }
            scheduleHeightUpdate(
                max(24, ceil(rawHeight)),
                width: (message.webView?.frame.width ?? 0).rounded()
            )
        }

        private func resolveSourceCards(for message: WKScriptMessage) {
            guard let values = message.body as? [Any] else { return }
            let tokens = values.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            let generation = sourceCardResolutionGeneration
            let resolver = sourceCardForToken
            let webView = message.webView
            Task { @MainActor [weak self, weak webView] in
                let cards = await ChatMarkdownView.sourceCardLookup(
                    tokens: tokens,
                    sourceCardForToken: resolver
                )
                guard let json = ChatMarkdownView.sourceCardJSON(cards), let self,
                      generation == self.sourceCardResolutionGeneration else { return }
                if let webView {
                    // The cards this row shows are what a drag off one of them
                    // names the source with — see `SourceLinkDrag`.
                    (webView as? ChatMarkdownWebView)?.rememberSourceCards(cards)
                    _ = try? await webView.evaluateJavaScript("window.setSourceCards(\(json));")
                }
            }
        }

        private func resolveSourceImages(for message: WKScriptMessage) {
            guard let values = message.body as? [Any] else { return }
            let tokens = values.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            let generation = sourceCardResolutionGeneration
            let resolver = sourceImageForToken
            let webView = message.webView
            Task { @MainActor [weak self, weak webView] in
                let images = await ChatMarkdownView.sourceImageLookup(tokens: tokens, sourceImageForToken: resolver)
                guard let json = ChatMarkdownView.sourceImageJSON(images), let self,
                      generation == self.sourceCardResolutionGeneration else { return }
                if let webView {
                    // What made each picture from the image store, for its
                    // right-click menu (`ChatMarkdownWebView.willOpenMenu`).
                    (webView as? ChatMarkdownWebView)?.rememberPictures(images)
                    _ = try? await webView.evaluateJavaScript("window.setSourceImages(\(json));")
                }
            }
        }

        /// The Copy button on a picture. Resolution is cached, so this is the
        /// same bytes the web view is showing, placed on the general pasteboard
        /// as an image other apps can paste.
        private func copySourceImage(for message: WKScriptMessage) {
            guard let token = (message.body as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty else { return }
            let resolver = sourceImageForToken
            Task { @MainActor in
                guard let image = await resolver(token) else { return }
                image.copyToPasteboard()
            }
        }

        /// A click on a picture. The same cached bytes the figure shows open
        /// full-window over the transcript's own window — a pop-out chat or a
        /// deep-link window as much as the Studio window — with the alt text
        /// as the caption.
        private func zoomSourceImage(for message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let token = (body["token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty else { return }
            let title = (body["alt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolver = sourceImageForToken
            let window = message.webView?.window
            Task { @MainActor in
                guard let image = await resolver(token) else { return }
                ChatImageLightbox.present(image, title: title?.isEmpty == false ? title : nil, over: window)
            }
        }

        /// Add to Notebook beside a Sources row: the source joins the chat's
        /// notebook, then this row's cards are asked for again, now unmarked.
        /// Every other row follows when the notebook's membership revision
        /// moves its `citationScopeKey`.
        private func addSourceToNotebook(for message: WKScriptMessage) {
            guard let token = (message.body as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty, let add = addSourceToNotebook else { return }
            let webView = message.webView
            Task { @MainActor [weak self, weak webView] in
                await add(token)
                guard let self, let webView else { return }
                self.refreshSourceCards(in: webView)
            }
        }

        /// Drops the cards the page holds and draws the message again, so it
        /// asks for every card afresh (`resolveSourceCards`).
        func refreshSourceCards(in webView: WKWebView) {
            sourceCardResolutionGeneration &+= 1
            webView.evaluateJavaScript("window.resetSourceCards();")
            webView.evaluateJavaScript(ChatMarkdownView.markdownPushScript(
                citationContext: lastCitationContext,
                markdown: lastMarkdown
            ))
        }

        /// Add beside a paper under a slide. Once the import returns, the
        /// picture is looked up again and handed back, which redraws its list
        /// with the paper as a link to the new source.
        private func addSlideCitedPaper(for message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let token = (body["token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let paperID = (body["paperID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty, !paperID.isEmpty,
                  let add = addSlideCitedPaper else { return }
            let resolver = sourceImageForToken
            let webView = message.webView
            Task { @MainActor [weak webView] in
                await add(paperID)
                guard let json = await ChatMarkdownView.sourceImageLookupJSON(
                    tokens: [token],
                    sourceImageForToken: resolver
                ), let webView else { return }
                _ = try? await webView.evaluateJavaScript("window.setSourceImages(\(json));")
            }
        }

        private func scheduleHeightUpdate(_ nextHeight: CGFloat, width: CGFloat) {
            pendingHeight = nextHeight
            pendingWidth = width
            heightUpdateTask?.cancel()
            heightUpdateTask = nil
            // A row's first measurement lands at once, scroll or no scroll: until
            // it does the row stands at a guess, and a guess held through a
            // scroll is the collapsed bubble that springs open when the wheel
            // stops. So does a change to a row above the visible region — its
            // growth is scrolled past in the same layout pass
            // (`ChatTranscriptScrollAnchoring`), so applying it costs the
            // learner nothing, and holding it would land it as a jump later.
            // What waits out a scroll is a row on or below the screen resizing
            // again: the streaming bubble, a dozen times a second.
            if !hasAppliedHeight || ChatTranscriptScrollAnchoring.rowStartsAboveVisibleRegion(webView) {
                applyPendingHeight()
                return
            }
            heightUpdateTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(48))
                guard !Task.isCancelled else { return }
                // Wait out a scroll in progress rather than resizing a row the
                // wheel is currently moving. A later report replaces this one,
                // so what lands afterwards is the newest height, not a stale one.
                while ChatScrollActivity.isScrolling {
                    try? await Task.sleep(for: .milliseconds(60))
                    guard !Task.isCancelled else { return }
                }
                self.applyPendingHeight()
            }
        }

        private func applyPendingHeight() {
            guard let reportedHeight = pendingHeight else { return }
            pendingHeight = nil
            hasAppliedHeight = true
            if remembersHeight, pendingWidth > 0 {
                ChatMarkdownHeightMemory.record(
                    height: reportedHeight,
                    width: pendingWidth,
                    fontSize: lastFontSize,
                    for: identity
                )
            }
            let current = height.wrappedValue
            guard abs(current - reportedHeight) > 1 else { return }
            ChatTranscriptScrollAnchoring.compensate(for: webView, growth: reportedHeight - current)
            height.wrappedValue = reportedHeight
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // While streaming, updateNSView pushes deltas the moment they arrive,
            // possibly before the page's scripts have run, so window.setMarkdown
            // isn't defined yet and those calls are dropped. Push the latest
            // content now that the page is ready, so a fast stream can't leave
            // the view blank. Same for a zoom change that raced the page load.
            webView.evaluateJavaScript("document.body.style.fontSize = '\(lastFontSize)px';")
            // A page that just loaded shows nothing yet, whatever was pushed at
            // it before its scripts existed, so this is a first paint and goes
            // at once even mid-scroll.
            hasPaintedMarkdown = false
            pushMarkdown(into: webView)
        }

        /// Open a source in a window of its own, or beside the chat when the
        /// row was built without a window route.
        func openSourceInNewWindow(_ link: ChatSourceLink) {
            (onOpenSourceInNewWindow ?? onOpenSource)(link)
        }

        /// What the web view's link menu does for a source link: Reader beside
        /// the chat, a window of its own, or one of the windows already open.
        func sourceLinkActions() -> ForeverLMWebView.SourceLinkActions {
            ForeverLMWebView.SourceLinkActions(
                openBeside: { [weak self] link in self?.onOpenSource(link) },
                openInNewWindow: { [weak self] link in self?.openSourceInNewWindow(link) },
                windowTargets: { [weak self] in self?.sourceWindowTargets?() ?? [] }
            )
        }

        /// WebKit asks for a window when the page opens a link in one: the
        /// menu's "Open Link in New Window", a Cmd-click, a target="_blank".
        /// A source link becomes a Studio window; a web address goes to the
        /// browser, the one place a new window for it can be; a doc or Notebook
        /// link opens in this Studio. No web view is ever made for it.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                if let link = ChatMarkdownView.sourceLink(from: url) {
                    openSourceInNewWindow(link)
                } else if let entity = StudioEntityLink.parse(url) {
                    NotificationCenter.default.post(name: .requestOpenStudioEntityLink, object: entity)
                } else if let cards = ChatSavedCards.parse(url) {
                    NotificationCenter.default.post(name: .requestOpenChatSavedCards, object: cards)
                } else {
                    NSWorkspace.shared.open(url)
                }
            }
            return nil
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                if let link = ChatMarkdownView.sourceLink(from: url) {
                    onOpenSource(link)
                } else if let entity = StudioEntityLink.parse(url) {
                    // A doc or Notebook a reply names opens in this Studio, never
                    // through LaunchServices, which would hand the scheme to
                    // whichever ForeverLM it registered last.
                    NotificationCenter.default.post(name: .requestOpenStudioEntityLink, object: entity)
                } else if let cards = ChatSavedCards.parse(url) {
                    // Cards a reply names inline, likewise: To Check here.
                    NotificationCenter.default.post(name: .requestOpenChatSavedCards, object: cards)
                } else if let scheme = url.scheme?.lowercased(),
                          scheme == "http" || scheme == "https" {
                    onOpenWebURL(url, nil)
                } else {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }

    static func sourceID(from url: URL) -> String? {
        // Chat links are always written with the production scheme, but a deep
        // link from outside the app arrives with the running build's own scheme
        // (`foreverlm-dev` in Dev), and both name the same source.
        let scheme = url.scheme?.lowercased()
        guard scheme == "foreverlm" || scheme == ForeverLMRuntimeIdentity.urlScheme.lowercased(),
              url.host?.lowercased() == "source" else { return nil }

        let sourceID = url.pathComponents
            .dropFirst()
            .first?
            .removingPercentEncoding?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sourceID, !sourceID.isEmpty else { return nil }
        return sourceID
    }

    /// The source a link names together with the moment its `t=` query asks
    /// for, the passage its `q=` query quotes and the page its `page=` query
    /// names, so a timed citation, a quoted one, a paged one and a plain one
    /// travel the same way.
    static func sourceLink(from url: URL) -> ChatSourceLink? {
        guard let sourceID = sourceID(from: url) else { return nil }
        return ChatSourceLink(
            sourceID: sourceID,
            seconds: SourceLinkTimeAnchor.seconds(in: url),
            passage: SourceLinkPassageAnchor.passage(in: url),
            page: SourceLinkPageAnchor.page(in: url)
        )
    }

    /// The message page, shipped inside the app bundle. `ChatRendererResources`
    /// is the build output of `Web/ChatRenderer`: the same renderer Web Studio
    /// runs, plus KaTeX and its fonts, so a reply renders the same way on both
    /// surfaces and nothing here waits on a CDN. Before this the page was a Swift
    /// string that loaded markdown-it, DOMPurify and KaTeX from jsdelivr, and an
    /// unreachable CDN left every reply as escaped plain text.
    static let templateURL: URL = {
        if let url = Bundle.main.url(
            forResource: "chat-render",
            withExtension: "html",
            subdirectory: "ChatRendererResources"
        ) {
            return url
        }
        // A test host built without the folder reference still finds the page.
        return Bundle.main.url(forResource: "chat-render", withExtension: "html")
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/ChatRendererResources/chat-render.html")
    }()

    /// How KaTeX draws an equation. "html" is KaTeX's own box model with the
    /// bundled fonts, which is what Mac chat has always shown. "mathml" would
    /// hand the equation to the system math font instead, needing neither the
    /// stylesheet nor the fonts; it changes the look of every equation, so it
    /// waits on a visual sign-off rather than being flipped here.
    static let mathOutput = "html"

    /// Runs before the page's own scripts so the renderer is created with the
    /// app's choices already on the root element.
    static var configurationScript: WKUserScript {
        WKUserScript(
            source: "document.documentElement.dataset.mathOutput = \(jsonString(mathOutput));",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }

    static func loadTemplate(into webView: WKWebView) {
        webView.loadFileURL(templateURL, allowingReadAccessTo: templateURL.deletingLastPathComponent())
    }

    /// Markdown and the citation context that explains it, as one statement.
    /// The page reads the context when it decorates the markdown, so the two can
    /// never be allowed to arrive out of order — sending them together is what
    /// guarantees they cannot.
    static func markdownPushScript(
        citationContext: ChatCitationLedger.MessageContext,
        markdown: String
    ) -> String {
        "window.setCitationContext(\(citationContextJSON(citationContext))); "
            + "window.setMarkdown(\(jsonString(markdown)));"
    }

    /// A context the page can use, or `null` for a message with nothing to say
    /// about the transcript — which leaves the renderer numbering from one and
    /// listing every source it cites.
    static func citationContextJSON(_ context: ChatCitationLedger.MessageContext) -> String {
        guard !context.isEmpty,
              let data = try? JSONEncoder().encode(context),
              let json = String(data: data, encoding: .utf8) else { return "null" }
        return json
    }

    private static func jsonString(_ value: String) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
        return String(data: data, encoding: .utf8) ?? "\"\""
    }

    /// Every requested token gets a response. Missing records encode as JSON
    /// null so the WebView can invalidate the link instead of leaving a
    /// plausible-looking blue citation on screen forever.
    @MainActor static func sourceCardLookupJSON(
        tokens: [String],
        sourceCardForToken: @MainActor (String) async -> ChatSourceCard?
    ) async -> String? {
        sourceCardJSON(await sourceCardLookup(tokens: tokens, sourceCardForToken: sourceCardForToken))
    }

    /// The card for every requested token, nil for a token the library does
    /// not know, each token asked once.
    @MainActor static func sourceCardLookup(
        tokens: [String],
        sourceCardForToken: @MainActor (String) async -> ChatSourceCard?
    ) async -> [String: ChatSourceCard?] {
        var cards: [String: ChatSourceCard?] = [:]
        for token in tokens where !token.isEmpty && cards[token] == nil {
            cards.updateValue(await sourceCardForToken(token), forKey: token)
        }
        return cards
    }

    static func sourceCardJSON(_ cards: [String: ChatSourceCard?]) -> String? {
        guard !cards.isEmpty,
              let data = try? JSONEncoder().encode(cards) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Every requested token gets a response, nil included, so the web view can
    /// mark a picture unavailable instead of leaving a placeholder forever.
    @MainActor static func sourceImageLookupJSON(
        tokens: [String],
        sourceImageForToken: @MainActor (String) async -> ChatSourceImage?
    ) async -> String? {
        sourceImageJSON(await sourceImageLookup(tokens: tokens, sourceImageForToken: sourceImageForToken))
    }

    /// The picture for every requested token, nil for one this device cannot
    /// show, each token asked once.
    @MainActor static func sourceImageLookup(
        tokens: [String],
        sourceImageForToken: @MainActor (String) async -> ChatSourceImage?
    ) async -> [String: ChatSourceImage?] {
        var images: [String: ChatSourceImage?] = [:]
        for token in tokens where !token.isEmpty && images[token] == nil {
            images.updateValue(await sourceImageForToken(token), forKey: token)
        }
        return images
    }

    static func sourceImageJSON(_ images: [String: ChatSourceImage?]) -> String? {
        // Base64 is a quarter slashes; the default encoder would write every
        // one as `\/` and grow each picture by that much for nothing.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard !images.isEmpty,
              let data = try? encoder.encode(images) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private final class ChatMarkdownWebView: WKWebView {
        /// No Apple Intelligence badge on a selection (`SharedWebKit.allowsWritingToolsAffordance(in:)`).
        @objc(allowsWritingToolsAffordance)
        var allowsWritingToolsAffordance: Bool { SharedWebKit.allowsWritingToolsAffordance(in: self) }

        /// The source cards this row has resolved, by the token the page asked
        /// with and by the source's own id, so a drag that starts on a card —
        /// or on a `foreverlm://source/<id>` link in the prose — can name the
        /// source the way the Sources sidebar names one it drags.
        private var sourceCards: [String: ChatSourceCard] = [:]

        func rememberSourceCards(_ cards: [String: ChatSourceCard?]) {
            for (token, card) in cards {
                guard let card else { continue }
                sourceCards[token] = card
                sourceCards[card.sourceID] = card
            }
        }

        func forgetSourceCards() {
            sourceCards.removeAll()
        }

        /// The pictures from the image store this row shows, by the token the
        /// page asked with: the version shown and what made it.
        private var pictureListings: [String: GeneratedImageStore.Listing] = [:]
        /// The picture the pointer was over when the menu was raised.
        private var contextPicture: (token: String, reportedAt: TimeInterval)?
        /// Redraw With's action, set by the coordinator that drives this row;
        /// nil while the view is parked in the pool, and then no picture
        /// lines are offered.
        var redrawPicture: (@MainActor (String, ImageGenerationModel) async -> Void)?

        func rememberPictures(_ images: [String: ChatSourceImage?]) {
            for (token, image) in images {
                pictureListings[token] = image?.generatedListing
            }
        }

        func forgetPictures() {
            pictureListings.removeAll()
            contextPicture = nil
        }

        func noteContextPicture(token: String?) {
            let token = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            contextPicture = token.isEmpty ? nil : (token, ProcessInfo.processInfo.systemUptime)
        }

        /// A picture from the image store says what made it and offers to be
        /// drawn again with another model, above WebKit's own image commands.
        /// The picture dims until its redraw lands in its place.
        private func insertPictureItems(in menu: NSMenu) {
            guard let redrawPicture, let contextPicture,
                  ProcessInfo.processInfo.systemUptime - contextPicture.reportedAt < 2,
                  let listing = pictureListings[contextPicture.token] else { return }
            let token = contextPicture.token
            let items = GeneratedImageRedraw.menuItems(for: listing, redraw: { [weak self] model in
                self?.dimPicture(token, true)
                Task { @MainActor [weak self] in
                    await redrawPicture(listing.id, model)
                    self?.dimPicture(token, false)
                }
            }, keep: { menuTargets.append($0) })
            guard !items.isEmpty else { return }
            let hadItems = !menu.items.isEmpty
            for (index, item) in items.enumerated() {
                menu.insertItem(item, at: index)
            }
            if hadItems {
                menu.insertItem(.separator(), at: items.count)
            }
        }

        private func dimPicture(_ token: String, _ dimmed: Bool) {
            evaluateJavaScript("""
                document.querySelectorAll('figure.source-image-figure').forEach(function(f) {
                    if (f.dataset.sourceImage === \(ChatMarkdownView.jsonString(token))) {
                        f.style.transition = 'opacity 0.2s';
                        f.style.opacity = '\(dimmed ? "0.4" : "")';
                    }
                }); undefined;
                """)
        }

        /// What the link commands act on, set by the coordinator that drives
        /// this row; nil while the view is parked in the pool.
        var sourceLinkActions: ForeverLMWebView.SourceLinkActions?
        /// The link the pointer was over when the menu was raised, as
        /// `ReaderContextLinkTracking` reported it: a source link, or an
        /// ordinary one.
        private var contextSourceLink: (link: ChatSourceLink, reportedAt: TimeInterval)?
        private var contextIsOrdinaryLink = false
        /// `NSMenuItem.target` is weak, so the adopted commands' closures are
        /// held here until the next menu opens — not until this one closes,
        /// because the chosen item's action has not been sent yet then.
        private var menuTargets: [MenuActionTarget] = []

        func noteContextLink(url: URL?) {
            if let url, let link = ChatMarkdownView.sourceLink(from: url) {
                contextSourceLink = (link, ProcessInfo.processInfo.systemUptime)
                contextIsOrdinaryLink = false
            } else {
                contextSourceLink = nil
                contextIsOrdinaryLink = url != nil
            }
        }

        /// WebKit's link commands answer in the web process, where a
        /// foreverlm:// address loads nothing: "Open Link" failed silently and
        /// "Open Link in New Window" did nothing at all. On a source link they
        /// become the app's own — Reader beside the chat, a window of its own,
        /// each other open window — and "Download Linked File" goes, since
        /// there is no file at that address. An ordinary link keeps WebKit's
        /// commands, its new window being the browser (`createWebViewWith`).
        private func adoptLinkItems(in menu: NSMenu) {
            let sourceLink: ChatSourceLink?
            if let contextSourceLink, ProcessInfo.processInfo.systemUptime - contextSourceLink.reportedAt < 2 {
                sourceLink = contextSourceLink.link
            } else if contextIsOrdinaryLink {
                sourceLink = nil
            } else {
                return
            }
            for item in menu.items {
                switch ForeverLMWebView.linkMenuDisposition(identifier: item.identifier?.rawValue, isSourceLink: sourceLink != nil) {
                case .keep:
                    continue
                case .remove:
                    menu.removeItem(item)
                case .openInBrowser:
                    item.title = "Open Link in Browser"
                case .openInReader:
                    guard let sourceLink, let actions = sourceLinkActions else { continue }
                    item.title = "Open in Reader"
                    retarget(item) { actions.openBeside(sourceLink) }
                case .openInNewWindow:
                    guard let sourceLink, let actions = sourceLinkActions else { continue }
                    item.title = "Open in New Window"
                    retarget(item) { actions.openInNewWindow(sourceLink) }
                    let index = menu.index(of: item)
                    for (offset, target) in actions.windowTargets().enumerated() {
                        let other = NSMenuItem(title: "Open in \(target.label)", action: #selector(MenuActionTarget.fire), keyEquivalent: "")
                        let handler = MenuActionTarget { target.open(sourceLink) }
                        menuTargets.append(handler)
                        other.target = handler
                        menu.insertItem(other, at: index + 1 + offset)
                    }
                }
            }
        }

        private func retarget(_ item: NSMenuItem, with run: @escaping () -> Void) {
            let target = MenuActionTarget(run: run)
            menuTargets.append(target)
            item.target = target
            item.action = #selector(MenuActionTarget.fire)
            item.representedObject = nil
        }

        override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
            super.didCloseMenu(menu, with: event)
            contextSourceLink = nil
            contextIsOrdinaryLink = false
            contextPicture = nil
        }

        /// WebKit starts a link drag with the link's address and title on the
        /// pasteboard and nothing an in-app destination recognises, which is
        /// how a chat card dropped on a Doc used to land as a bare private
        /// address. The session is this view's own (WebKit names the web view
        /// as the drag's source), so the moment it begins the source payload
        /// the sidebar's drag carries is added beside WebKit's items. WebKit's
        /// own handling of the moment runs first, through the implementation
        /// this method stands in front of; the header does not declare it, so
        /// it is reached by selector rather than by `super`.
        @objc(draggingSession:willBeginAtPoint:)
        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            SourceLinkDrag.forwardWillBegin(to: WKWebView.self, receiver: self, session: session, screenPoint: screenPoint)
            SourceLinkDrag.claim(session.draggingPasteboard) { [weak self] token in
                guard let card = self?.sourceCards[token] else { return nil }
                return StudioArticleTransfer(
                    articleId: card.sourceID,
                    articleIds: [card.sourceID],
                    title: card.title,
                    sourceType: card.kind
                )
            }
        }

        /// WebKit builds the context menu in the web process and offers it
        /// here, so this is where a reply's own commands join it. The page
        /// posts the passage through the same `selectionAction` channel the
        /// bar over the selection uses, so both routes land identically.
        override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
            super.willOpenMenu(menu, with: event)
            menuTargets.removeAll()
            adoptLinkItems(in: menu)
            insertPictureItems(in: menu)
            // WebKit offers Copy only over a selection; without one there is
            // nothing to act on and the items would do nothing.
            guard menu.items.contains(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierCopy" }) else {
                return
            }
            let hadItems = !menu.items.isEmpty
            for (index, action) in ChatReplySelectionAction.allCases.enumerated() {
                let item = NSMenuItem(
                    title: action.menuTitle,
                    action: #selector(runSelectionActionFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.image = NSImage(systemSymbolName: action.symbolName, accessibilityDescription: action.menuTitle)
                item.representedObject = action.rawValue
                item.target = self
                menu.insertItem(item, at: index)
            }
            if hadItems {
                menu.insertItem(.separator(), at: ChatReplySelectionAction.allCases.count)
            }
        }

        @objc private func runSelectionActionFromMenu(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String,
                  let action = ChatReplySelectionAction(rawValue: raw) else { return }
            evaluateJavaScript(
                "window.requestSelectionAction && window.requestSelectionAction('\(action.rawValue)'); undefined;"
            )
        }

        override func scrollWheel(with event: NSEvent) {
            ChatScrollActivity.noteScrollEvent()
            guard abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) else {
                super.scrollWheel(with: event)
                return
            }

            var ancestor = superview
            while let view = ancestor {
                if let scrollView = view as? NSScrollView {
                    scrollView.scrollWheel(with: event)
                    return
                }
                ancestor = view.superview
            }

            nextResponder?.scrollWheel(with: event)
        }
    }
}

/// A `foreverlm://source/<id>` link dragged out of a web view — a chat's
/// Sources row, a source card in a reply — becomes the drag the Sources sidebar
/// starts, so every destination in the app that takes a source takes it: the
/// Doc page writes a card or attaches the source, a Notebook files it, a chat adds it to its context. Without this the drag carried only
/// what WebKit gives a link — its address and its words — and a Doc pasted the
/// private address as text (2026-09-12).
enum SourceLinkDrag {
    static let sourceTransferType = NSPasteboard.PasteboardType(UTType.studioArticle.identifier)
    static let urlNameType = NSPasteboard.PasteboardType("public.url-name")

    /// The source id a dragged link names, or nil for a drag of anything else.
    /// Read from the pasteboard's URL, with the plain string as the fallback a
    /// browser's link drag leaves.
    static func sourceToken(on pasteboard: NSPasteboard) -> String? {
        var candidates: [String] = []
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            candidates.append(contentsOf: urls.map(\.absoluteString))
        }
        if let string = pasteboard.string(forType: .URL) { candidates.append(string) }
        if let string = pasteboard.string(forType: .string) { candidates.append(string) }
        for candidate in candidates {
            if let token = KnowledgeStore.sourceAddressToken(candidate.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return token
            }
        }
        return nil
    }

    /// The title WebKit wrote beside the link, when it wrote one.
    static func linkTitle(on pasteboard: NSPasteboard) -> String? {
        let title = pasteboard.string(forType: urlNameType)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return title?.isEmpty == false ? title : nil
    }

    /// Add the in-app source payload to a drag that carries a source link.
    /// `transfer` names the source from what the dragging view knows; when it
    /// knows nothing the id itself and the link's words stand in, since every
    /// destination resolves the id against the library. A drag that is not a
    /// source link, or already carries the payload, is left as it is. Returns
    /// what was written.
    @discardableResult
    static func claim(_ pasteboard: NSPasteboard, transfer: (String) -> StudioArticleTransfer?) -> StudioArticleTransfer? {
        guard pasteboard.availableType(from: [sourceTransferType]) == nil,
              let token = sourceToken(on: pasteboard) else { return nil }
        let payload = transfer(token) ?? StudioArticleTransfer(
            articleId: token,
            articleIds: [token],
            title: linkTitle(on: pasteboard) ?? token,
            sourceType: ""
        )
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        pasteboard.addTypes([sourceTransferType], owner: nil)
        guard pasteboard.setData(data, forType: sourceTransferType) else { return nil }
        return payload
    }

    private typealias WillBeginIMP = @convention(c) (AnyObject, Selector, NSDraggingSession, NSPoint) -> Void
    private static let willBeginSelector = NSSelectorFromString("draggingSession:willBeginAtPoint:")

    /// Whether `owner` implements the drag-session hook itself — WKWebView
    /// does, in a category its header does not declare, which is why a
    /// subclass cannot reach it with `super`.
    static func implementsWillBegin(_ owner: AnyClass) -> Bool {
        class_getInstanceMethod(owner, willBeginSelector) != nil
    }

    /// Run `owner`'s own `draggingSession(_:willBeginAt:)` on `receiver`, when
    /// it has one, so a subclass standing in front of it changes nothing about
    /// what the class did at the start of a drag.
    static func forwardWillBegin(to owner: AnyClass, receiver: AnyObject, session: NSDraggingSession, screenPoint: NSPoint) {
        guard let method = class_getInstanceMethod(owner, willBeginSelector) else { return }
        let implementation = unsafeBitCast(method_getImplementation(method), to: WillBeginIMP.self)
        implementation(receiver, willBeginSelector, session, screenPoint)
    }
}
