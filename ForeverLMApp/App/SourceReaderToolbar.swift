#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The docked reader has one toolbar policy, independent of source type or
/// surrounding panel state. `AdaptiveReaderToolbar` tries these presentations
/// in order against the width SwiftUI actually proposes, so a long title or a
/// state control cannot push the trailing ⋯ and close offscreen.
///
/// What the bar carries at all is the Quiet chrome rule (docs/ui-design.md,
/// 2026-10-06): the way back, the title, Add to Sources on a page the library
/// does not hold, and what is under way now — Listen while it prepares or
/// plays, a walkthrough, explainer or cards being written, "Cards · N to
/// check" while drafts wait. Every other Reader command lives in the ⋯ at
/// every width, so the tiers below trade only labels and the source icon.
enum ReaderToolbarDensity: String, CaseIterable {
    case expanded
    case standard
    case compact

    static let fitOrder: [Self] = [.expanded, .standard, .compact]

    var minimumIdentityWidth: CGFloat {
        switch self {
        case .expanded: return 180
        case .standard: return 112
        case .compact: return 44
        }
    }

    var showsSourceIcon: Bool { self != .compact }
    var showsLoadingIndicator: Bool { self != .compact }
    /// Whether state on the bar is spelled out — Listen's "Preparing audio…" —
    /// or kept to its glyph.
    var showsStatusText: Bool { self == .expanded }

    var pageActionStyle: ReaderToolbarPageActionStyle {
        switch self {
        case .expanded: return .labeled
        case .standard: return .iconOnly
        case .compact: return .hidden
        }
    }
}

enum ReaderToolbarPageActionStyle: Equatable {
    case labeled
    case iconOnly
    case hidden
}

enum ReaderAddPageToolbarState: Equatable {
    case available
    case adding
    case saved

    init(isAdding: Bool, isSaved: Bool) {
        if isAdding {
            self = .adding
        } else if isSaved {
            self = .saved
        } else {
            self = .available
        }
    }

    var systemImage: String {
        switch self {
        case .available: return "text.badge.plus"
        case .adding: return "hourglass"
        case .saved: return "checkmark"
        }
    }

    var title: String {
        switch self {
        case .available: return "Add to Sources"
        case .adding: return "Adding…"
        case .saved: return "View in Sources"
        }
    }

    var help: String {
        switch self {
        case .available: return "Add current page to Sources"
        case .adding: return "Adding to Sources"
        case .saved: return "Open the saved source in the Reader"
        }
    }

    /// The completed state is a way in, not a receipt. A page the library
    /// already holds — saved just now, or saved long ago under another
    /// address — reads View in Sources, and the click opens that source in
    /// the Reader (`opensSavedSource`); the Reader's copy carries the notes,
    /// highlights and reading position the live page never will.
    var isEnabled: Bool { self != .adding }

    /// Whether a click on this state opens the saved source instead of
    /// starting an import.
    var opensSavedSource: Bool { self == .saved }

    /// Immediate acknowledgement for every accepted click. Completion replaces
    /// this message with the exact result once persistence finishes.
    var activationMessage: String {
        switch self {
        case .available, .adding: return "Adding to Sources…"
        case .saved: return "Already in Sources"
        }
    }
}

/// A four-region toolbar: stable navigation, a flexible source identity,
/// width-dependent state, and mandatory trailing chrome. Every interactive
/// control that owns presentation state (browser navigation, Go to Page, the
/// overflow with its Contents and cited-sources popovers, and close) renders
/// only once; adaptive fit candidates contain the identity and the state
/// controls that are actually allowed to change presentation.
struct AdaptiveReaderToolbar<Leading: View, Identity: View, Actions: View, Trailing: View>: View {
    private let leading: () -> Leading
    private let identity: (ReaderToolbarDensity) -> Identity
    private let actions: (ReaderToolbarDensity) -> Actions
    private let trailing: () -> Trailing

    init(
        @ViewBuilder leading: @escaping () -> Leading,
        @ViewBuilder identity: @escaping (ReaderToolbarDensity) -> Identity,
        @ViewBuilder actions: @escaping (ReaderToolbarDensity) -> Actions,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.leading = leading
        self.identity = identity
        self.actions = actions
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 10) {
            // Navigation is primary reader chrome. Render one stable control
            // instance outside ViewThatFits so a density measurement or
            // transition can never own the click instead of the visible button
            // or replace a presented popover.
            leading()
                .fixedSize(horizontal: true, vertical: false)

            ViewThatFits(in: .horizontal) {
                adaptiveContent(for: .expanded)
                adaptiveContent(for: .standard)
                adaptiveContent(for: .compact)
            }

            // Menus and close are also mandatory interactive chrome; they do
            // not need to be duplicated merely to measure adaptive actions.
            trailing()
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func adaptiveContent(for density: ReaderToolbarDensity) -> some View {
        HStack(spacing: 10) {
            identity(density)
                .frame(
                    minWidth: density.minimumIdentityWidth,
                    maxWidth: .infinity,
                    alignment: .leading
                )
                .layoutPriority(1)

            actions(density)
                .fixedSize(horizontal: true, vertical: false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader.toolbar.\(density.rawValue)")
    }
}

struct SourceReaderToolbarIdentity: View {
    let density: ReaderToolbarDensity
    let title: String
    let positionLabel: String?
    let sourceSystemImage: String?
    /// The saved source the reader shows, when it shows one. Its icon and title
    /// then drag the source anywhere a Sources row goes — into a chat's context
    /// above all — so a source scrolled out of the sidebar can still be handed
    /// to the chat beside it. Nil while the reader has browsed off to a page
    /// that is not in the library.
    var draggableSource: StudioArticle? = nil
    /// Whether a chat is on screen to drop the source into. The title drags
    /// either way; while a chat is showing, a grip at its head says so, while
    /// the pointer is over the line (Quiet chrome, docs/ui-design.md,
    /// 2026-10-06: it was drawn whenever a chat was on screen).
    var showsChatDragIcon = false

    @State private var isPointerOverLine = false

    var body: some View {
        HStack(spacing: 4) {
            if showsChatDragIcon, let draggableSource {
                // Faded rather than removed, so the title does not shift
                // under the pointer as it arrives; its handle stays live.
                SourceReaderChatDragIcon(source: draggableSource, title: title)
                    .opacity(isPointerOverLine ? 1 : 0)
                    .animation(.easeOut(duration: 0.15), value: isPointerOverLine)
            }

            HStack(spacing: 6) {
                if density.showsSourceIcon, let sourceSystemImage {
                    Image(systemName: sourceSystemImage)
                        .foregroundStyle(.secondary)
                }

                titleView
                    .layoutPriority(1)
            }
            // Over the icon and words only, not the full-width frame below: the
            // rest of the header stays titlebar, so the window still moves by it.
            // It is there for a page the library does not hold too, without the
            // drag, for its right-click Copy Title.
            .overlay {
                SourceReaderTitleDragHandle(source: draggableSource, title: title)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .layoutPriority(1)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background {
            if showsChatDragIcon && draggableSource != nil {
                ReaderTitleLineHoverTracker { isPointerOverLine = $0 }
            }
        }
    }

    @ViewBuilder
    private var titleView: some View {
        if let positionLabel {
            VStack(alignment: .leading, spacing: 1) {
                titleText
                Text(positionLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else {
            titleText
        }
    }

    private var titleText: some View {
        Text(title)
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/// The grip that drags the source on screen into the chat beside it: six dots
/// at the head of the reader's title, shown only while a chat is on screen to
/// take it, and in the docked Reader only while the pointer is over the title
/// line. The title drags the same way; the grip is what says it can.
struct SourceReaderChatDragIcon: View {
    let source: StudioArticle
    let title: String

    @Environment(\.uiZoomScale) private var uiZoomScale
    @State private var isHovering = false

    var body: some View {
        Image(systemName: "circle.grid.2x3.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 18 * uiZoomScale, height: 22 * uiZoomScale)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
            }
            .overlay {
                SourceReaderTitleDragHandle(
                    source: source,
                    title: title,
                    toolTip: "Drag into the chat",
                    onHoverChange: { isHovering = $0 }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            // A drag has no accessibility route, as for the title beside it.
            .accessibilityHidden(true)
    }
}

extension StudioWindowState {
    /// Whether a chat of this window is on screen to drop a source into: the
    /// active tab of a pane — the chat or the one opened beside it — or popped
    /// out into a window of its own.
    var showsChatToDropInto: Bool {
        if isChatPoppedOut { return true }
        return centerTabGroups.groups.contains { group in
            group.activeTab == .chat || group.activeTab == .secondaryChat
        }
    }
}

/// The reader title as a drag handle for the source it names, the way a
/// document window's proxy icon is one.
///
/// It has to be AppKit for the same reason the center and source-type tabs
/// are (see `StudioCenterTabDragHandle`): the toolbar hangs into the titlebar
/// band, where a SwiftUI `.onDrag` loses the mouse-down to a window move. This
/// view owns the left mouse, so a moved press starts a real `NSDraggingSession`
/// carrying the payload `articleDragProvider` gives a Sources row — the
/// `.studioArticle` transfer and the `.studioSourceID` — which every in-app
/// source destination already takes, the chat's `StudioDropCatcher` included.
/// A still click does nothing, a double-click keeps the titlebar's own
/// double-click action, and a right- or control-click opens Copy Title: a
/// drag handle's words cannot be selected the way other text can.
///
/// With no source (a page the library does not hold) it only answers the
/// right-click, and every left press stays ordinary titlebar.
struct SourceReaderTitleDragHandle: NSViewRepresentable {
    let source: StudioArticle?
    let title: String
    var toolTip = "Drag into a chat to add it to the context"
    /// Pointer in and out, for a handle that paints its own hover wash. It
    /// comes from this view's tracking area, as a band button's does from
    /// `TitlebarBandHitSurfaceView`'s.
    var onHoverChange: ((Bool) -> Void)? = nil

    func makeNSView(context: Context) -> SourceReaderTitleDragHandleView {
        let view = SourceReaderTitleDragHandleView()
        // The title text underneath stays the accessibility element; a drag
        // has no accessibility route.
        view.setAccessibilityElement(false)
        update(view)
        return view
    }

    func updateNSView(_ nsView: SourceReaderTitleDragHandleView, context: Context) {
        update(nsView)
    }

    private func update(_ view: SourceReaderTitleDragHandleView) {
        view.source = source
        view.title = title
        view.toolTip = source == nil ? nil : toolTip
        view.onHoverChange = onHoverChange
    }
}

final class SourceReaderTitleDragHandleView: NSView, NSDraggingSource {
    private static let registeredHandles = NSHashTable<SourceReaderTitleDragHandleView>.weakObjects()
    private static var mouseDownMonitor: Any?

    var source: StudioArticle? {
        didSet {
            // The open hand is only for a title that drags.
            if (oldValue == nil) != (source == nil) {
                window?.invalidateCursorRects(for: self)
            }
        }
    }
    var title = ""
    var onHoverChange: ((Bool) -> Void)?

    private var hoverTrackingArea: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        guard source != nil else { return }
        addCursorRect(bounds, cursor: .openHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }

    override func cursorUpdate(with event: NSEvent) {
        if source != nil {
            NSCursor.openHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            Self.registeredHandles.remove(self)
            onHoverChange?(false)
        } else {
            Self.registeredHandles.add(self)
            Self.installMouseDownMonitorIfNeeded()
        }
    }

    /// The docked reader's header hangs into the titlebar band by a SwiftUI
    /// offset, and there AppKit hit-tests a press to the hosting view, not to
    /// this one, and reads it as a window move — the reason the band's buttons
    /// go through `TitlebarBandHitSurfaceView`'s router. A handle routes its
    /// own presses the same way: a left press inside a handle that drags is
    /// handed to it, a right- or control-click inside any handle opens its
    /// Copy Title, and every other click stays ordinary titlebar.
    private static func installMouseDownMonitorIfNeeded() {
        guard mouseDownMonitor == nil else { return }
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            guard let eventWindow = event.window else { return event }
            let isContextClick = event.type == .rightMouseDown || event.modifierFlags.contains(.control)
            guard let handle = registeredHandle(
                at: event.locationInWindow,
                in: eventWindow,
                drags: !isContextClick
            ) else { return event }
            if isContextClick {
                handle.showTitleMenu(with: event)
            } else {
                handle.mouseDown(with: event)
            }
            return nil
        }
    }

    private static func registeredHandle(
        at point: NSPoint,
        in window: NSWindow,
        drags: Bool
    ) -> SourceReaderTitleDragHandleView? {
        registeredHandles.allObjects
            .filter { handle in
                handle.window === window
                    && (!drags || handle.source != nil)
                    && !handle.isHiddenOrHasHiddenAncestor
                    && handle.convert(handle.bounds, to: nil).contains(point)
            }
            // The grip and the title never overlap, but prefer the tightest
            // if a transitional layout briefly places two at one point.
            .min { lhs, rhs in
                lhs.bounds.width * lhs.bounds.height < rhs.bounds.width * rhs.bounds.height
            }
    }

    /// Own a press only where the title drags, so another page's title stays
    /// ordinary titlebar. A right- or control-click never gets this far: the
    /// router above takes it first and opens Copy Title.
    override func hitTest(_ point: NSPoint) -> NSView? {
        source == nil ? nil : super.hitTest(point)
    }

    /// The title's one context command. Its words cannot be selected — a
    /// press on them starts the drag — so this is how they are copied.
    private func showTitleMenu(with event: NSEvent) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let copy = NSMenuItem(title: "Copy Title", action: #selector(copyTitle(_:)), keyEquivalent: "")
        copy.target = self
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copy.isEnabled = !title.isEmpty
        menu.addItem(copy)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func copyTitle(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(title, forType: .string)
    }

    /// Consume the whole press here, as a band button does: a routed press
    /// never made this the window's mouse-down view, so the drags that follow
    /// would go to the titlebar's window move unless this loop takes them.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            performTitlebarDoubleClickAction()
            return
        }
        guard let window else { return }
        let start = event.locationInWindow
        window.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout: NSEvent.foreverDuration,
            mode: .eventTracking
        ) { [weak self] tracked, stop in
            guard let self, let tracked, tracked.type == .leftMouseDragged else {
                stop.pointee = true
                return
            }
            let now = tracked.locationInWindow
            guard hypot(now.x - start.x, now.y - start.y) > 4 else { return }
            stop.pointee = true
            self.beginSourceDrag(with: tracked)
        }
    }

    private func beginSourceDrag(with event: NSEvent) {
        guard let source else { return }
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem(for: source))
        let ghost = dragGhostImage()
        item.setDraggingFrame(NSRect(origin: .zero, size: ghost.size), contents: ghost)
        // Lights the same drop zones a Sources row drag does.
        StudioDragVisibility.shared.begin(articleIDs: [source.id])
        // Start from the event that crossed the threshold; the original
        // mouse-down leaves AppKit free to continue a titlebar window move.
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // Destinations propose copy or move for a source; allow either, as a
        // SwiftUI item-provider drag from a Sources row does.
        context == .withinApplication ? [.copy, .move, .generic] : []
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        StudioDragVisibility.shared.endSoon()
        // The pointer left during the drag without an exit reaching this view.
        onHoverChange?(false)
    }

    private func pasteboardItem(for source: StudioArticle) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        let transfer = StudioArticleTransfer.dragging(source, draggedIDs: [source.id])
        if let data = try? JSONEncoder().encode(transfer) {
            item.setData(data, forType: NSPasteboard.PasteboardType(UTType.studioArticle.identifier))
        }
        item.setString(source.id, forType: NSPasteboard.PasteboardType(UTType.studioSourceID.identifier))
        return item
    }

    /// What a double-click on an empty stretch of titlebar does, from the
    /// system setting the Dock pane writes.
    private func performTitlebarDoubleClickAction() {
        guard let window else { return }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize":
            window.performMiniaturize(nil)
        case "None":
            break
        default:
            window.performZoom(nil)
        }
    }

    /// This view is transparent, so snapshotting it would drag an empty rect.
    private func dragGhostImage() -> NSImage {
        let text = title as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        let textSize = text.size(withAttributes: attributes)
        let textWidth = min(textSize.width, 220)
        let size = NSSize(width: textWidth + 20, height: 24)
        return NSImage(size: size, flipped: false) { rect in
            let pill = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
            NSColor.windowBackgroundColor.withAlphaComponent(0.9).setFill()
            pill.fill()
            NSColor.separatorColor.setStroke()
            pill.stroke()
            text.draw(
                with: NSRect(
                    x: 10,
                    y: (rect.height - textSize.height) / 2,
                    width: textWidth,
                    height: textSize.height
                ),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: attributes
            )
            return true
        }
    }
}

/// Stable navigation for the adaptive reader toolbar. Keeping browser buttons
/// and the stateful Go to Page popover outside its fit candidates guarantees
/// that the control receiving a click is the same instance the learner sees
/// and hovers. In particular, `ViewThatFits` may construct and measure more
/// than one candidate; a popover inside those candidates can otherwise open
/// from an off-screen copy or disappear when the selected density changes.
/// A book's Contents is not here: it opens from the ⋯ (Quiet chrome,
/// 2026-10-06), as a popover off that button.
struct SourceReaderStableNavigation: View {
    let showsBrowserNavigation: Bool
    let canGoBack: Bool
    let canGoForward: Bool
    /// What ‹ says it does: "Go back", or "Back to <place>" when it shows
    /// again what the Reader covered in its pane.
    var backHelp = "Go back"
    /// The reader's page position, when its document is counted in pages.
    /// Presenting the Go to Page popover from here, the one toolbar view that
    /// is never rebuilt by a density change, keeps it anchored to a control
    /// that stays on screen while it is open.
    var pageNavigation: ReaderPageNavigation? = nil
    var isGoToPagePresented: Binding<Bool> = .constant(false)
    var goToPage: (Int) -> Void = { _ in }
    let goBack: () -> Void
    let goForward: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            SourceReaderBrowserNavigation(
                isVisible: showsBrowserNavigation,
                canGoBack: canGoBack,
                canGoForward: canGoForward,
                backHelp: backHelp,
                goBack: goBack,
                goForward: goForward
            )

            if pageNavigation != nil {
                // The keyboard route to Go to Page. The button itself draws
                // nothing; the command is listed, with this shortcut, in the
                // reader's overflow menu.
                Button("Go to Page…") {
                    isGoToPagePresented.wrappedValue = true
                }
                .keyboardShortcut(ReaderGoToPage.shortcutKey, modifiers: ReaderGoToPage.shortcutModifiers)
                .hidden()
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
        }
        .popover(isPresented: isGoToPagePresented, arrowEdge: .bottom) {
            if let pageNavigation {
                ReaderGoToPagePopover(
                    navigation: pageNavigation,
                    goToPage: goToPage,
                    dismiss: { isGoToPagePresented.wrappedValue = false }
                )
            }
        }
    }
}

/// The Go to Page command: its shortcut, shared by the hidden toolbar button
/// that fires it and the overflow menu item that lists it.
enum ReaderGoToPage {
    static let shortcutKey: KeyEquivalent = "g"
    static let shortcutModifiers: EventModifiers = [.command, .option]
}

/// A page number, typed and jumped to. Return goes; Escape closes the popover
/// as any popover closes.
struct ReaderGoToPagePopover: View {
    let navigation: ReaderPageNavigation
    let goToPage: (Int) -> Void
    let dismiss: () -> Void
    @State private var entry = ""
    @FocusState private var isEntryFocused: Bool

    private var target: Int? {
        navigation.pageIndex(forEntry: entry)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Go to Page")
                .font(.headline)
            HStack(spacing: 8) {
                // `Text(verbatim:)`: a localized key would print the page
                // as "1,379", a form the field itself does not need.
                TextField(text: $entry, prompt: Text(verbatim: "\(navigation.currentPage + 1)")) {
                    Text("Page")
                }
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                    .focused($isEntryFocused)
                    .onSubmit(submit)
                    .accessibilityLabel("Page number")
                    .accessibilityIdentifier("reader.goToPage.field")
                Text("of \(navigation.pageCount)")
                    .foregroundStyle(.secondary)
                Button("Go", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(target == nil)
                    .accessibilityIdentifier("reader.goToPage.go")
            }
        }
        .padding(14)
        .onAppear {
            entry = ""
            isEntryFocused = true
        }
    }

    private func submit() {
        guard let target else { return }
        goToPage(target)
        dismiss()
    }
}

struct SourceReaderBrowserNavigation: View {
    let isVisible: Bool
    let canGoBack: Bool
    let canGoForward: Bool
    var backHelp = "Go back"
    let goBack: () -> Void
    let goForward: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            // Back belongs to the Reader itself, so it remains present for
            // every source type. For a live page it first follows WebKit's
            // page history; otherwise it restores the previous source in this
            // pane. Forward remains page-specific until source-level forward
            // history is part of the Reader contract.
            ReaderNavigationButton(
                systemImage: "chevron.left",
                help: backHelp,
                isEnabled: canGoBack,
                action: goBack
            )
            if isVisible {
                ReaderNavigationButton(
                    systemImage: "chevron.right",
                    help: "Go forward",
                    isEnabled: canGoForward,
                    action: goForward
                )
            }
        }
    }
}

/// What the docked Reader's bar shows between the title and the ⋯: the page
/// loading, Add to Sources on a page the library does not hold, and what is
/// under way now (Quiet chrome, docs/ui-design.md, 2026-10-06). Listen shows
/// only while it prepares, makes a narration or plays; an explainer or a
/// walkthrough only while it is being written; cards while they are drafted
/// or wait to be checked. Each starts from the ⋯: Listen, Walk Through,
/// Make Cards, Levels and Contents sit at the top of `SourceReaderPanel`'s
/// overflow menu at every width, Explain and Clip under its Make ▸, and Chat
/// About This Video under its Video ▸.
struct SourceReaderToolbarActions: View {
    @ObservedObject var speech: ArticleSpeechService

    let density: ReaderToolbarDensity
    let article: StudioArticle
    let isSavedSource: Bool
    let showsLoadingIndicator: Bool
    let addPageState: ReaderAddPageToolbarState?
    let addPage: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if density.showsLoadingIndicator && showsLoadingIndicator {
                ProgressView()
                    .controlSize(.small)
            }

            if let addPageState, density.pageActionStyle != .hidden {
                ReaderAddPageToolbarButton(
                    state: addPageState,
                    showsTitle: density.pageActionStyle == .labeled,
                    action: addPage
                )
            }

            if isSavedSource {
                // State, so on every width tier: hiding it would hide what is
                // happening. Idle, Listen is the ⋯ menu's.
                ArticleSpeechControls(
                    speech: speech,
                    article: article,
                    showsTitle: false,
                    showsPreparationStatus: density.showsStatusText,
                    showsListenWhenIdle: false
                )
                if GeneratedExplainer.canExplain(article) {
                    ExplainerToolbarButton(article: article)
                }
                WalkthroughToolbarButton(article: article)
                if CardsToolbarButton.canMakeCards(from: article) {
                    CardsToolbarButton(article: article)
                }
            }
        }
        // A narration Listen made, landing while this Reader still shows its
        // source, plays — the Listen control that used to take it is off the
        // bar once the narration is no longer being made.
        .onChange(of: speech.madeNarrationSourceID) { _, sourceID in
            guard isSavedSource, sourceID == article.id else { return }
            speech.takeMadeNarration(article)
        }
    }
}

/// An icon button for a reader toolbar row, wherever that row is mounted.
///
/// Docked in a Studio window the row hangs in the titlebar band, where a SwiftUI
/// `Button` neither lights up under the pointer nor receives its mouse-down —
/// AppKit hands the press to the window drag instead (see
/// `TitlebarBandHitSurfaceView`). The pop-out reader's `NSToolbar` and in-flow
/// toolbars have no such problem. The host says which it is through
/// `studioTitlebarBandControls`, and this renders the matching control with the
/// same hover-wash look, so a shared control such as Listen or Stop Making Cards
/// is written once and works in both.
struct ReaderToolbarButton<Label: View>: View {
    let help: String
    var accessibilityLabel: String? = nil
    var accessibilityIdentifier: String? = nil
    /// The label's square; the wash and click target reach `washInset` past it.
    var controlSize: CGFloat = StudioPanelChrome.readerCloseButtonSize
    /// Width of the label slot when it is wider than `controlSize`.
    var controlWidth: CGFloat? = nil
    var washInset: CGFloat = 5
    let action: () -> Void
    @ViewBuilder var label: () -> Label

    @Environment(\.studioTitlebarBandControls) private var onTitlebarBand

    var body: some View {
        if onTitlebarBand {
            TitlebarBandButton(
                help: help,
                accessibilityLabel: accessibilityLabel,
                accessibilityIdentifier: accessibilityIdentifier,
                washInset: washInset,
                controlSize: controlSize,
                controlWidth: controlWidth,
                action: action,
                label: label
            )
        } else {
            Button(action: action) {
                label()
                    .frame(width: controlWidth ?? controlSize, height: controlSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(inset: -washInset))
            .help(help)
            .accessibilityLabel(accessibilityLabel ?? help)
            .accessibilityIdentifier(accessibilityIdentifier ?? "")
        }
    }
}

/// "Add to Sources" for a live web page, wherever the reader toolbar is mounted.
/// Same split as `ReaderNavigationButton`: in the titlebar band a native
/// `NSButton` lights up but never receives its mouse-down (see
/// `TitlebarBandHitSurfaceView`), so the band host gets a `TitlebarBandButton`
/// and every other toolbar keeps the native button.
struct ReaderAddPageToolbarButton: View {
    let state: ReaderAddPageToolbarState
    let showsTitle: Bool
    let action: () -> Void

    @Environment(\.studioTitlebarBandControls) private var onTitlebarBand

    var body: some View {
        let title = showsTitle ? state.title : nil
        if onTitlebarBand {
            TitlebarBandButton(
                help: state.help,
                accessibilityIdentifier: ReaderTitlebarActionButton.addPageAccessibilityIdentifier,
                controlSize: StudioPanelChrome.readerCloseButtonSize,
                controlWidth: ReaderTitlebarActionButton.bandControlWidth(
                    title: title,
                    controlSize: StudioPanelChrome.readerCloseButtonSize
                ),
                isEnabled: state.isEnabled,
                action: action
            ) {
                ReaderTitlebarActionLabel(
                    systemImage: state.systemImage,
                    title: title,
                    isEnabled: state.isEnabled
                )
            }
        } else {
            ReaderAddPageNativeButton(state: state, showsTitle: showsTitle, action: action)
        }
    }
}

/// The native form of `ReaderAddPageToolbarButton`, for toolbars outside the
/// titlebar band. The button is the actual hit target and refuses window
/// dragging, so the mouse and accessibility paths execute the same action.
struct ReaderAddPageNativeButton: NSViewRepresentable {
    let state: ReaderAddPageToolbarState
    let showsTitle: Bool
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> ReaderTitlebarActionButton {
        let button = ReaderTitlebarActionButton()
        button.target = context.coordinator
        button.action = #selector(Coordinator.performAction(_:))
        return button
    }

    func updateNSView(_ button: ReaderTitlebarActionButton, context: Context) {
        context.coordinator.action = action
        button.configure(state: state, showsTitle: showsTitle)
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func performAction(_ sender: NSButton) {
            action()
        }
    }
}

@MainActor
final class ReaderTitlebarActionButton: NSButton {
    static let addPageAccessibilityIdentifier = "reader.addPage"

    static func accessibilityIdentifier(forSystemImage systemImage: String) -> String {
        "reader.navigation.\(systemImage)"
    }

    /// The label slot a band-mounted copy of this control needs. A bare symbol
    /// fits the shared square; a titled control (the labeled "Add to Sources")
    /// widens by the title's measured width, the symbol beside it, and the
    /// same 8pt this button's `intrinsicContentSize` adds around a title. The
    /// band button frames its label at exactly this width, and its native hit
    /// surface at this width plus the wash, so the measurement is what keeps
    /// the click target under the drawn label.
    static func bandControlWidth(title: String?, controlSize: CGFloat) -> CGFloat {
        guard let title, !title.isEmpty else { return controlSize }
        let titleWidth = (title as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
        ]).width
        let symbolWidth: CGFloat = 16
        let spacing: CGFloat = 4
        return ceil(max(controlSize, symbolWidth + spacing + titleWidth + 8))
    }

    private var hoverTrackingArea: NSTrackingArea?
    private var hovering = false {
        didSet { updateHoverBackground() }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setButtonType(.momentaryChange)
        bezelStyle = .inline
        isBordered = false
        focusRingType = .none
        imageScaling = .scaleProportionallyDown
        wantsLayer = true
        layer?.cornerRadius = 6
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
    }

    func configure(state: ReaderAddPageToolbarState, showsTitle: Bool) {
        configure(
            systemImage: state.systemImage,
            title: showsTitle ? state.title : nil,
            help: state.help,
            isEnabled: state.isEnabled,
            accessibilityIdentifier: Self.addPageAccessibilityIdentifier
        )
    }

    func configure(
        systemImage: String,
        title: String?,
        help: String,
        isEnabled: Bool,
        accessibilityIdentifier: String
    ) {
        let foreground = isEnabled ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor
        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        image = NSImage(systemSymbolName: systemImage, accessibilityDescription: help)?
            .withSymbolConfiguration(symbolConfiguration)
        contentTintColor = foreground
        imagePosition = title == nil ? .imageOnly : .imageLeading
        attributedTitle = NSAttributedString(
            string: title ?? "",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
                .foregroundColor: foreground,
            ]
        )
        self.isEnabled = isEnabled
        toolTip = help
        setAccessibilityLabel(help)
        setAccessibilityIdentifier(accessibilityIdentifier)
        invalidateIntrinsicContentSize()
        updateHoverBackground()
    }

    override var intrinsicContentSize: NSSize {
        let fitting = super.intrinsicContentSize
        return NSSize(width: max(26, fitting.width + (title.isEmpty ? 0 : 8)), height: 24)
    }

    private func updateHoverBackground() {
        layer?.backgroundColor = hovering && isEnabled
            ? NSColor.labelColor.withAlphaComponent(0.08).cgColor
            : NSColor.clear.cgColor
    }
}

/// Clip, in the Reader's ⋯ menu: turns the Clip tool on or off in the PDF
/// showing this source in the key window (`ReaderClipTool`). Only where the
/// Canvas shows (`BetaFeatures`), on a source the Reader shows as pages. While
/// the tool is on the page says so — its hint across the top, or the box and
/// its actions — and Escape turns it off.
struct ReaderClipMenuItem: View {
    let article: StudioArticle
    let isOn: Bool

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .readerClipToolToggle, object: nil, userInfo: ["sourceID": article.id])
        } label: {
            Label(isOn ? "Stop Clipping" : "Clip", systemImage: "scissors")
        }
        .help("Clip a figure: drag a box round it, or click it, then drag it onto the Canvas (or ⌥-drag on the page)")
    }
}

// MARK: - A paper's other versions in the ⋯

/// **Versions ▸** in the Reader's ⋯ for a paper whose preprint or journal version the library also
/// holds (docs/paper-versions.md): open the other version, and, from a preprint, move the notebook
/// the window works in onto the journal version. Absent for a paper with no other version. The
/// menu's items are built when the ⋯ is pressed, so the library is read then and never in a render.
struct PaperVersionsMenuItems: View {
    @Environment(StudioViewModel.self) private var vm
    let article: StudioArticle
    let windowState: StudioWindowState?

    var body: some View {
        let published = vm.publishedVersion(ofPreprint: article.id)
        let earlier = vm.earlierVersions(ofPublished: article.id)
        if published != nil || !earlier.isEmpty {
            Menu {
                if let published {
                    Button {
                        Task { await vm.revealSourceInReader(published.id) }
                    } label: {
                        Label("Open Published Version", systemImage: "doc.text")
                    }
                    if let notebook = vm.notebookInScope(for: windowState ?? vm.activeWindowState),
                       vm.notebookMembership(of: [vm.canonicalSourceID(article.id)], in: notebook.id) == .all {
                        Button {
                            Task { await vm.switchNotebookToPublishedVersion(ofPreprint: article.id, notebookID: notebook.id) }
                        } label: {
                            Label("Use Published Version in \u{201C}\(notebook.title)\u{201D}", systemImage: "arrow.triangle.swap")
                        }
                    }
                }
                ForEach(earlier, id: \.id) { preprint in
                    Button {
                        Task { await vm.revealSourceInReader(preprint.id) }
                    } label: {
                        Label(earlier.count > 1 ? "Open Preprint: \(preprint.title)" : "Open Preprint", systemImage: "doc.text")
                    }
                }
            } label: {
                Label("Versions", systemImage: "square.on.square")
            }
        }
    }
}

// MARK: - A reader's own commands in the ⋯

/// Commands a reader view keeps state for, listed in the Reader's ⋯. Until
/// Quiet chrome (docs/ui-design.md, 2026-10-06) a video's slides, papers and
/// transcript layout sat on a bar above its transcript, and a podcast's
/// Speakers menu on a row of its own; they are the ⋯'s **Video ▸** and
/// **Speakers ▸** now, under the same names. The reader on screen publishes
/// them here as its state changes and withdraws them as it leaves; the docked
/// Reader's ⋯, built at each press, and the pop-out's read them for the
/// source they show. Handed to the readers through the environment.
@MainActor
@Observable
final class ReaderMenuCommands {
    var video: ReaderVideoCommands?
    var speakers: ReaderSpeakerCommands?

    func video(for sourceID: String) -> ReaderVideoCommands? {
        video?.sourceID == sourceID ? video : nil
    }

    func speakers(for sourceID: String) -> ReaderSpeakerCommands? {
        speakers?.sourceID == sourceID ? speakers : nil
    }
}

/// A YouTube video's commands (`YouTubeVideoReaderView`): capture the slides,
/// read them for the papers they cite, the papers found, and where the
/// transcript sits beside the player.
struct ReaderVideoCommands {
    let sourceID: String
    /// Show Slides, while the slides are not up and no capture came back empty.
    var showSlides: (() -> Void)?
    /// Extract Papers, offered from the start: it captures the slides first
    /// when they are missing.
    var extractPapers: (() -> Void)?
    /// Papers, once the slides have named some: the whole video's list.
    var showPapers: (() -> Void)?
    var pendingPaperCount = 0
    var hasSlides = false
    var isCapturingSlides = false
    var isExtractingPapers = false
    var transcriptBesideVideo = true
    var toggleTranscriptPlacement: () -> Void
    var isTranscriptHidden = false
    var toggleTranscriptHidden: () -> Void
    var isTheaterMode = false
    var toggleTheaterMode: () -> Void
}

/// A podcast's speaker commands (`TranscriptReaderView`).
struct ReaderSpeakerCommands {
    let sourceID: String
    var isBusy = false
    var updateWithAI: () -> Void
    var editManually: () -> Void
}

/// **Video ▸** in the Reader's ⋯: Chat About This Video where the Reader has
/// a chat beside it, then what the video reader publishes once its
/// transcript is on screen.
struct ReaderVideoMenu: View {
    let chatAboutVideo: (() -> Void)?
    let commands: ReaderVideoCommands?

    var body: some View {
        Menu {
            if let chatAboutVideo {
                Button(action: chatAboutVideo) {
                    Label("Chat About This Video", systemImage: "bubble.left")
                }
            }
            if let commands {
                if chatAboutVideo != nil {
                    Divider()
                }
                if let showPapers = commands.showPapers {
                    Button(action: showPapers) {
                        Label(
                            commands.pendingPaperCount > 0
                                ? "Papers (\(commands.pendingPaperCount) to add)"
                                : "Papers",
                            systemImage: "doc.text.magnifyingglass"
                        )
                    }
                    .help("Papers cited on this video's slides")
                }
                if let showSlides = commands.showSlides {
                    Button(action: showSlides) {
                        Label(
                            commands.isCapturingSlides ? "Showing Slides…" : "Show Slides",
                            systemImage: "rectangle.on.rectangle.angled"
                        )
                    }
                    .disabled(commands.isCapturingSlides || commands.isExtractingPapers)
                    .help("Capture this video's slides and show them alongside the transcript")
                }
                if let extractPapers = commands.extractPapers {
                    Button(action: extractPapers) {
                        Label(
                            commands.isExtractingPapers ? "Extracting Papers…" : "Extract Papers",
                            systemImage: "doc.text.magnifyingglass"
                        )
                    }
                    .disabled(commands.isCapturingSlides || commands.isExtractingPapers)
                    .help(commands.hasSlides
                        ? "Read this video's slides for the papers they cite"
                        : "Capture this video's slides, then read them for the papers they cite")
                }
                Divider()
                Button(action: commands.toggleTranscriptPlacement) {
                    Label(
                        commands.transcriptBesideVideo ? "Move Transcript Below Video" : "Move Transcript Beside Video",
                        systemImage: commands.transcriptBesideVideo ? "rectangle.split.1x2" : "rectangle.split.2x1"
                    )
                }
                .disabled(commands.isTheaterMode || commands.isTranscriptHidden)
                Button(action: commands.toggleTranscriptHidden) {
                    Label(
                        commands.isTranscriptHidden ? "Show Transcript" : "Hide Transcript",
                        systemImage: commands.isTranscriptHidden ? "sidebar.right" : "eye.slash"
                    )
                }
                .disabled(commands.isTheaterMode)
                .help("Hide the transcript — give the whole pane to the video")
                Toggle(isOn: Binding(
                    get: { commands.isTheaterMode },
                    set: { _ in commands.toggleTheaterMode() }
                )) {
                    Label("Theater View", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .help("Theater view: the video fills the pane over the live caption line")
            }
        } label: {
            Label("Video", systemImage: "play.rectangle")
        }
    }
}

/// **Speakers ▸** in the Reader's ⋯, for a podcast whose transcript names
/// its speakers.
struct ReaderSpeakersMenu: View {
    let commands: ReaderSpeakerCommands

    var body: some View {
        Menu {
            Button(action: commands.updateWithAI) {
                Label("Update Speakers with AI", systemImage: "sparkles")
            }
            .disabled(commands.isBusy)
            Button(action: commands.editManually) {
                Label("Edit Speakers Manually…", systemImage: "person.2.badge.gearshape")
            }
            .disabled(commands.isBusy)
        } label: {
            Label("Speakers", systemImage: "person.wave.2")
        }
    }
}

// MARK: - The title line under the pointer

/// Reports the pointer entering and leaving the Reader's title line, for
/// chrome that shows only then: the grip that drags the source into a chat.
/// An AppKit tracking area, as the band's own buttons use
/// (`TitlebarBandHitSurfaceView`), because the line hangs in the titlebar
/// band; and no hit target, so every press still reaches the controls and
/// the window drag around them.
struct ReaderTitleLineHoverTracker: NSViewRepresentable {
    let onHoverChange: (Bool) -> Void

    func makeNSView(context: Context) -> ReaderTitleLineHoverTrackingView {
        let view = ReaderTitleLineHoverTrackingView()
        view.setAccessibilityElement(false)
        view.onHoverChange = onHoverChange
        return view
    }

    func updateNSView(_ nsView: ReaderTitleLineHoverTrackingView, context: Context) {
        nsView.onHoverChange = onHoverChange
    }
}

final class ReaderTitleLineHoverTrackingView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { onHoverChange?(false) }
    }
}
#endif
