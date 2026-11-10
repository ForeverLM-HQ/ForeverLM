// Drag visibility, drop zones, panel and tab-group sizing, and the centre tab drag payloads.

import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// `@Observable` deliberately: nearly every row in the app (chat rows, notebook
/// rows, source rows, drop panels) consults this object. As an
/// `ObservableObject`, one drag beginning or ending invalidated every observer
/// at once — the sample traces showed a chat drag re-diffing the entire
/// Sources table. Per-property tracking means a row only re-renders when a
/// property it actually reads changes, and the guarded setters below keep
/// untouched properties from notifying at all.
@Observable
final class StudioDragVisibility {
    static let shared = StudioDragVisibility()

    private(set) var isDragging = false
    private(set) var draggedArticleIds: Set<String> = []
    private(set) var draggedGroupName: String?
    private(set) var draggedNotebookID: String?
    private(set) var draggedSessionID: String?
    private(set) var draggedCenterTab: StudioCenterTab?
    /// The Doc a Docs-list row or doc-title drag is carrying, beside the Docs
    /// pane itself.
    private(set) var draggedArtifactID: String?
    /// The Goal a Goals-tab row drag is carrying: the other rows draw an
    /// insertion line for it, and no source drop zone lights up.
    private(set) var draggedGoalID: String?
    /// The Space place a Space sidebar row or a kept shortcut is carrying:
    /// the icon strip draws it where it would land and keeps it there.
    private(set) var draggedRailShortcut: StudioRailShortcut?
    /// The strip icon being dragged up or down its group: the strip moves
    /// it as the drag goes.
    private(set) var draggedStripEntry: StudioStripEntry?

    /// True while a whole pane is being dragged — Schedule, Docs, Notebooks, or
    /// New chat on its way to its own side-by-side pane. A pane drag carries no
    /// source payload, so every content drop zone (notebook rows, schedule days,
    /// the chat panel) must stay hidden: the only destination that can take it
    /// is the center area's edge split.
    ///
    /// A Docs-list row is the exception: its drag carries the Docs pane, so the
    /// edge split still opens Docs beside, and the doc itself, which the chat
    /// can take. Only a bare pane drag hides the content drop zones.
    ///
    /// A Space place on its way to the icon strip counts too, with or without
    /// a pane: it carries no source either, and the strip is its destination.
    var isPaneDrag: Bool {
        (draggedCenterTab != nil || draggedRailShortcut != nil || draggedStripEntry != nil) && draggedArtifactID == nil
    }

    @ObservationIgnored private var resetTask: Task<Void, Never>?
    @ObservationIgnored private var mouseButtonReleaseTask: Task<Void, Never>?
    @ObservationIgnored private var localMouseUpMonitor: Any?
    @ObservationIgnored private var globalMouseUpMonitor: Any?

    func begin(
        articleIDs: [String] = [],
        groupName: String? = nil,
        notebookID: String? = nil,
        sessionID: String? = nil,
        centerTab: StudioCenterTab? = nil,
        artifactID: String? = nil,
        goalID: String? = nil,
        railShortcut: StudioRailShortcut? = nil,
        stripEntry: StudioStripEntry? = nil
    ) {
        setDragState(
            isDragging: true,
            draggedArticleIds: Set(articleIDs),
            draggedGroupName: groupName,
            draggedNotebookID: notebookID,
            draggedSessionID: sessionID,
            draggedCenterTab: centerTab,
            draggedArtifactID: artifactID,
            draggedGoalID: goalID,
            draggedRailShortcut: railShortcut,
            draggedStripEntry: stripEntry
        )
        NSCursor.closedHand.set()
        installMouseUpMonitors()
        watchForMouseButtonRelease()
        scheduleReset(after: 8)
    }

    func endSoon() {
        // A mouse-up ends AppKit's dragging session before SwiftUI delivers the
        // destination's `perform` closure. Publishing `isDragging = false` in
        // that same event turn rebuilds every observing source row and drop
        // zone, which can remove the destination before it accepts the payload.
        // Keep the visual drag state alive for one short delivery window; an
        // accepted drop still calls this method, while the release monitors
        // cover drags that end over no destination.
        scheduleReset(after: 0.2)
    }

    func endNow() {
        resetTask?.cancel()
        resetTask = nil
        setDragState(
            isDragging: false,
            draggedArticleIds: [],
            draggedGroupName: nil,
            draggedNotebookID: nil,
            draggedSessionID: nil,
            draggedCenterTab: nil,
            draggedArtifactID: nil,
            draggedGoalID: nil,
            draggedRailShortcut: nil,
            draggedStripEntry: nil
        )
        mouseButtonReleaseTask?.cancel()
        mouseButtonReleaseTask = nil
        removeMouseUpMonitors()
        NSCursor.arrow.set()
    }

    private func setDragState(
        isDragging: Bool,
        draggedArticleIds: Set<String>,
        draggedGroupName: String?,
        draggedNotebookID: String?,
        draggedSessionID: String?,
        draggedCenterTab: StudioCenterTab?,
        draggedArtifactID: String?,
        draggedGoalID: String?,
        draggedRailShortcut: StudioRailShortcut?,
        draggedStripEntry: StudioStripEntry?
    ) {
        // `@Observable` notifies a property's observers on every write, equal
        // value or not, so each assignment is guarded — a chat drag must not
        // re-render source rows that only read `draggedArticleIds`.
        if self.isDragging != isDragging { self.isDragging = isDragging }
        if self.draggedArticleIds != draggedArticleIds { self.draggedArticleIds = draggedArticleIds }
        if self.draggedGroupName != draggedGroupName { self.draggedGroupName = draggedGroupName }
        if self.draggedNotebookID != draggedNotebookID { self.draggedNotebookID = draggedNotebookID }
        if self.draggedSessionID != draggedSessionID { self.draggedSessionID = draggedSessionID }
        if self.draggedCenterTab != draggedCenterTab { self.draggedCenterTab = draggedCenterTab }
        if self.draggedArtifactID != draggedArtifactID { self.draggedArtifactID = draggedArtifactID }
        if self.draggedGoalID != draggedGoalID { self.draggedGoalID = draggedGoalID }
        if self.draggedRailShortcut != draggedRailShortcut { self.draggedRailShortcut = draggedRailShortcut }
        if self.draggedStripEntry != draggedStripEntry { self.draggedStripEntry = draggedStripEntry }
    }

    private func scheduleReset(after seconds: TimeInterval) {
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            let nanoseconds = UInt64(seconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            endNow()
        }
    }

    private func watchForMouseButtonRelease() {
        mouseButtonReleaseTask?.cancel()
        mouseButtonReleaseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            while !Task.isCancelled {
                guard NSEvent.pressedMouseButtons != 0 else {
                    endSoon()
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    private func installMouseUpMonitors() {
        removeMouseUpMonitors()
        localMouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp]) { [weak self] event in
            DispatchQueue.main.async {
                self?.endSoon()
            }
            return event
        }
        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.endSoon()
            }
        }
    }

    private func removeMouseUpMonitors() {
        if let localMouseUpMonitor {
            NSEvent.removeMonitor(localMouseUpMonitor)
            self.localMouseUpMonitor = nil
        }
        if let globalMouseUpMonitor {
            NSEvent.removeMonitor(globalMouseUpMonitor)
            self.globalMouseUpMonitor = nil
        }
    }
}

struct StudioDropZoneOverlay: View {
    let isActive: Bool
    var isVisible: Bool = false
    var title: String? = nil
    var systemImage: String = "arrow.down.doc"
    var cornerRadius: CGFloat = 10
    var inset: CGFloat = 6

    var body: some View {
        let shown = isActive || isVisible
        RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(
                Color.accentColor.opacity(isActive ? 0.95 : (shown ? 0.65 : 0)),
                style: StrokeStyle(lineWidth: isActive ? 2.5 : 2, dash: [7, 5])
            )
            .background(
                Color.accentColor.opacity(isActive ? 0.14 : (shown ? 0.06 : 0)),
                in: RoundedRectangle(cornerRadius: cornerRadius)
            )
            .padding(inset)
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.12), value: shown)
    }
}

/// Clears a stuck `onDrop(isTargeted:)` binding once the drag that set it is over.
///
/// AppKit tells a destination that a drag left it only while the session is
/// live. A drop that lands somewhere else, a drag cancelled with Escape, or a
/// row that SwiftUI rebuilt mid-drag can leave the last `isTargeted = true`
/// standing, and the row keeps its dashed drop outline until the next drag
/// happens to cross it. Every such drag ends with the mouse button released,
/// so that release is the reliable end signal: once no button is down the
/// binding is cleared after a short delivery window, long enough for the
/// destination's `perform` closure to run first (see
/// `StudioDragVisibility.endSoon`).
struct DropTargetWatchdogModifier: ViewModifier {
    @Binding var isTargeted: Bool
    @State private var watchdog: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onChange(of: isTargeted) { _, targeted in
                watchdog?.cancel()
                watchdog = nil
                guard targeted else { return }
                watchdog = Task { @MainActor in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        guard !Task.isCancelled else { return }
                        guard NSEvent.pressedMouseButtons == 0 else { continue }
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        guard !Task.isCancelled else { return }
                        if isTargeted { isTargeted = false }
                        return
                    }
                }
            }
            .onDisappear {
                watchdog?.cancel()
                watchdog = nil
            }
    }
}

extension View {
    /// Resets `isTargeted` when the drag that set it has ended without AppKit
    /// reporting the exit. Pair with any `onDrop(isTargeted:)` whose binding
    /// drives a visible highlight.
    func dropTargetWatchdog(_ isTargeted: Binding<Bool>) -> some View {
        modifier(DropTargetWatchdogModifier(isTargeted: isTargeted))
    }
}

// MARK: - Draggable panel layout

enum StudioPanelDefaultSizing {
    static let goldenRatio: CGFloat = 1.618_033_988_75

    /// The width the sidebar opens at so that every center pane is exactly
    /// φ times as wide as it. The row is sized as if an equal side column
    /// shared the window, which keeps the center φ times a side however wide
    /// the window is. Solving
    ///
    ///     window = 2·side + panes·φ·side + panes·divider
    ///
    /// for `side` is what keeps that ratio true at any window size — a
    /// pinned point width holds only at one width and drifts everywhere else
    /// (at 2560pt it stretched the center to 2.5× the sides).
    ///
    /// Splitting the center narrows the sidebar, since the row now owes φ to
    /// two panes instead of one.
    static func goldenSideWidth(windowWidth: CGFloat, centerPaneCount: Int) -> CGFloat {
        let panes = CGFloat(max(1, centerPaneCount))
        let dividers = panes * StudioOuterPanelSizing.dividerWidth
        let side = (windowWidth - dividers) / (2 + panes * goldenRatio)
        return min(max(side, StudioNavigationRail.minRailWidth), StudioNavigationRail.maxRailWidth)
    }
}

/// Keeps adjacent panes usable while a divider moves. When the available span
/// cannot fit both minimums (for example in a genuinely narrow window), the
/// divider retains its ordinary hard bounds and the existing clipping behavior
/// remains the last resort.
enum StudioPaneDividerConstraint {
    static func clamp(
        _ proposed: CGFloat,
        hardLower: CGFloat,
        hardUpper: CGFloat,
        leadingMinimumWidth: CGFloat,
        trailingMinimumWidth: CGFloat,
        usableWidth: CGFloat
    ) -> CGFloat {
        let hardClamped = min(max(proposed, hardLower), hardUpper)
        guard usableWidth > 0,
              (hardUpper - hardLower) * usableWidth >= leadingMinimumWidth + trailingMinimumWidth
        else { return hardClamped }

        let lower = hardLower + leadingMinimumWidth / usableWidth
        let upper = hardUpper - trailingMinimumWidth / usableWidth
        guard lower <= upper else { return hardClamped }
        return min(max(hardClamped, lower), upper)
    }
}

/// Width contract for the center column: the pane minimum, and the gap a
/// divider between two center panes takes.
enum StudioOuterPanelSizing {
    static let dividerWidth: CGFloat = 10
    static let minimumContentWidth: CGFloat = 200
}

// MARK: - Center tab groups

/// Shared width contract for the center groups and the Studio shell's
/// reader-chat space policy. Keeping these values in one place prevents the
/// shell from deciding a layout fits while a pane is already clipping content.
enum StudioCenterTabGroupSizing {
    static let dividerWidth: CGFloat = 10
    static let minimumContentWidth: CGFloat = 200
    static let minimumChatContentWidth: CGFloat = 360
    /// The widest supported two-pane combination is Chat plus one ordinary
    /// workspace pane. Side panels can collapse, but the window itself must
    /// never become narrower than this chrome-free center arrangement.
    static let minimumWindowContentWidth = minimumChatContentWidth
        + minimumContentWidth
        + dividerWidth

    static func minimumWidth(for groups: [StudioCenterTabGroups.Group]) -> CGFloat {
        guard !groups.isEmpty else { return 0 }
        let contentWidth = groups.reduce(CGFloat.zero) { result, group in
            result + (ShellPlaces.descriptor(for: group.activeTab).role == .thread
                ? minimumChatContentWidth
                : minimumContentWidth)
        }
        return contentWidth + CGFloat(groups.count - 1) * dividerWidth
    }

    /// How much of one group's column the *enclosing* column clips off its
    /// trailing edge.
    ///
    /// The outer Reader column lays the groups out at the sum of their minima
    /// and clips the result at its real width, anchored leading. That clipping
    /// starts at the enclosing column's visible edge and eats leftwards, so it
    /// reaches only the groups whose columns extend past that edge — the last
    /// group first, and the ones before it only once the last is gone
    /// entirely. Handing the whole clipped amount to every group instead
    /// pushed the first pane's corner controls left by the full overflow, onto
    /// the traffic lights, while that pane was completely on screen.
    ///
    /// - Parameters:
    ///   - groupStart: The group's leading edge in the groups layout.
    ///   - groupWidth: The group's column width in that layout.
    ///   - totalWidth: The groups layout's full width (what the enclosing
    ///     column laid it out at).
    ///   - enclosingOverflow: How much of that width the enclosing column
    ///     clips away at the trailing edge.
    /// - Returns: The clipped width of this group, between zero and its width.
    static func clippedTrailingWidth(
        groupStart: CGFloat,
        groupWidth: CGFloat,
        totalWidth: CGFloat,
        enclosingOverflow: CGFloat
    ) -> CGFloat {
        let visibleEnd = totalWidth - max(0, enclosingOverflow)
        let groupEnd = groupStart + groupWidth
        return min(max(0, groupWidth), max(0, groupEnd - visibleEnd))
    }
}

extension StudioViewModel {
    /// Whether the Reader in `windowState` holds a video: a YouTube video, a
    /// video source, a generated explainer, or a meeting with a playable
    /// recording. Its tab then says Video, since a Reader names a document.
    func readerShowsVideo(in windowState: StudioWindowState) -> Bool {
        let article: StudioArticle?
        if let external = windowState.externalReaderPage {
            article = external.article
        } else {
            article = windowState.readerSourceID(fallingBackTo: selectedArticleId).flatMap { articlesById[$0] }
        }
        guard let article else { return false }
        if article.offersWatchedMarks || article.isYouTubeURL || GeneratedExplainerVideo.isVideoURL(article.url) {
            return true
        }
        return article.sourceType == .meeting
            && MeetingRecordingMedia.resolve(from: meetingArtifactsBySourceId[article.id] ?? []) != nil
    }
}

extension StudioViewModel {
    /// A Space place's name as the learner reads it: a team's, a space's and a
    /// list's are their own; every other place's is its fixed title.
    func spacePlaceTitle(_ destination: SpaceDestination) -> String {
        switch destination {
        case .team(let id):
            return teams.first { $0.id == id }?.name ?? "Space"
        case .space(let id):
            return pageSpaces.space(id)?.name ?? "Space"
        case .list(let id):
            return spaceLists.list(id)?.name ?? "List"
        default:
            return destination.title
        }
    }

    /// What the window's Space tab is called: the place it shows (Plan, Pages,
    /// a team's name), so two Space tabs in two windows read apart (product
    /// owner, 2026-11-08: "instead of just showing space here, in the tab
    /// title, maybe it should show what the exact space is"). All, the
    /// landing list, keeps the name Space.
    func spaceTabTitle(in windowState: StudioWindowState) -> String {
        let destination = SpaceDestination(key: windowState.spaceDestinationKey)
        return destination == .all ? StudioCenterTab.artifacts.title : spacePlaceTitle(destination)
    }
}

extension StudioCenterTab {
    /// What a tab in a strip is called: the Reader says Video while it holds
    /// one, and the Space names the place it shows (`spaceTabTitle`).
    func stripTitle(readerShowsVideo: Bool, spaceTitle: String? = nil) -> String {
        switch self {
        case .reader where readerShowsVideo: return "Video"
        case .artifacts: return spaceTitle ?? title
        default: return title
        }
    }

    /// The glyph a tab in a strip draws: the Reader draws a player while it
    /// holds a video.
    func stripSystemImage(readerShowsVideo: Bool) -> String {
        self == .reader && readerShowsVideo ? "play.rectangle" : ShellPlaces.descriptor(for: self).glyph
    }
}

private extension StudioCenterTab {
    /// Familiar, monochrome symbols help distinguish peer destinations without
    /// introducing another color system into the titlebar: the place
    /// registry's glyph (`ShellPlaces`).
    var systemImage: String { ShellPlaces.descriptor(for: self).glyph }
}

/// Where a dragged center tab would land.
enum StudioCenterTabDropTarget: Equatable {
    /// Insert before the tab at `index` in `group`.
    case tab(group: Int, index: Int)
    /// Append at the end of `group`'s strip.
    case stripEnd(group: Int)
    /// Split into a new group at the far edge of the center area.
    case edge(leading: Bool)
}

/// The private pasteboard contract used by center-tab drags. Keep the prefix
/// explicit so the edge destinations can reject ordinary text and source
/// drags without depending on SwiftUI's transient drag state.
enum StudioCenterTabDragPayload {
    private static let prefix = "centerTab:"
    /// Marks the rail's "New chat" row, which drags the Chat destination but
    /// means "a fresh conversation" — the same thing its click and its Open
    /// Beside menu item do. An ordinary Chat tab drag carries the loaded
    /// conversation and never this suffix.
    private static let blankChatSuffix = "?new"

    /// What a center-tab drag is asking for: which destination, and whether it
    /// should arrive on a blank conversation.
    struct Payload: Equatable {
        let tab: StudioCenterTab
        var startsBlankChat = false
    }

    /// A private type keeps native Reader/Chat text views from competing with
    /// the edge split destination for what would look like an ordinary text
    /// drag. Keep UTF-8 text alongside it so the SwiftUI strip delegates retain
    /// compatibility with drags started by older builds.
    static let contentType = UTType(exportedAs: "com.foreverlm.studio-center-tab")
    static let pasteboardType = NSPasteboard.PasteboardType(contentType.identifier)
    static let dropTypes: [UTType] = [contentType, .utf8PlainText]

    static func string(for tab: StudioCenterTab, startsBlankChat: Bool = false) -> String {
        prefix + tab.rawValue + (startsBlankChat ? blankChatSuffix : "")
    }

    static func pasteboardItem(for tab: StudioCenterTab, startsBlankChat: Bool = false) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        let payload = string(for: tab, startsBlankChat: startsBlankChat)
        item.setString(payload, forType: pasteboardType)
        item.setString(payload, forType: .string)
        return item
    }

    static func payload(from rawValue: String) -> Payload? {
        guard rawValue.hasPrefix(prefix) else { return nil }
        var body = String(rawValue.dropFirst(prefix.count))
        var startsBlankChat = false
        if body.hasSuffix(blankChatSuffix) {
            body = String(body.dropLast(blankChatSuffix.count))
            startsBlankChat = true
        }
        guard let tab = StudioCenterTab(rawValue: body) else { return nil }
        return Payload(tab: tab, startsBlankChat: startsBlankChat)
    }

    static func tab(from rawValue: String) -> StudioCenterTab? {
        payload(from: rawValue)?.tab
    }
}

/// A tab on its way out of a window's strip, kept app-wide while the drag
/// lasts so another window's strip, panes and edges can take it and the window
/// it left can let it go (product owner, 2026-11-08: "if I have a chat on my
/// right display I need to be able to drag it and then pop it over to the
/// other window"). The pasteboard says only which place is dragged; the
/// window, the pane and the chat it came from stay in this process, like
/// `NotebookOutputDragPayload`. One drag at a time.
enum StudioCenterTabWindowDrag {
    struct Origin {
        let window: StudioWindowState
        let groupID: UUID
        let tab: StudioCenterTab
        /// For a chat place: the pane's chat store, the chat tab dragged, and
        /// the chat it shows (nil for a chat not yet sent).
        var chatStore: StudioAssistantSessionStore?
        var chatTabID: UUID?
        var chatSessionID: String?
    }

    private static var current: Origin?
    private static var generation = 0

    static func begin(_ origin: Origin) {
        generation += 1
        current = origin
    }

    /// The drag session is over. Forgotten a moment later rather than at
    /// once, so a destination that hears of the drop after the source does
    /// still finds where it came from.
    static func endSoon() {
        let ended = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if generation == ended { current = nil }
        }
    }

    static func endNow() {
        current = nil
    }

    /// The tab in flight when it left a window other than `window`, and is
    /// `tab` when one is named (what the pasteboard says): nil for a drag
    /// within one window, or for a drag that did not start on a strip.
    static func arriving(in window: StudioWindowState, tab: StudioCenterTab? = nil) -> Origin? {
        guard let current, current.window !== window else { return nil }
        if let tab, tab != current.tab { return nil }
        return current
    }
}

func studioCenterTabDragProvider(
    for tab: StudioCenterTab,
    startsBlankChat: Bool = false
) -> NSItemProvider {
    let provider = NSItemProvider()
    let payload = StudioCenterTabDragPayload.string(for: tab, startsBlankChat: startsBlankChat)
    let data = Data(payload.utf8)
    provider.registerDataRepresentation(
        forTypeIdentifier: StudioCenterTabDragPayload.contentType.identifier,
        visibility: .ownProcess
    ) { completion in
        completion(data, nil)
        return nil
    }
    provider.suggestedName = tab.title
    return provider
}

/// The drag a Docs-list or Sites-list row, or the title above an open doc, starts.
///
/// It carries the record's own pane — Docs for a doc, Sites for a site — so the
/// center area's edge split still opens that pane beside, what dragging a row
/// has always done, and the record itself, so a chat the drag lands on attaches
/// it the way its "Add to Chat" item does. The two ride on one provider: a
/// destination reads the type it registered for and never sees the other.
func studioArtifactDragProvider(for artifact: ArtifactRecord) -> NSItemProvider {
    let provider = studioCenterTabDragProvider(for: artifact.section.centerTab)
    let transfer = StudioArtifactTransfer(artifactID: artifact.id, title: artifact.title)
    if let data = try? JSONEncoder().encode(transfer) {
        // `.all`, not `.ownProcess`: this is the representation the chat's
        // SwiftUI `.onDrop` matches on, and every in-app source drag that
        // reaches that drop registers its payload `.all`. The center-tab
        // representation the provider already carries stays own-process — it
        // only feeds the AppKit edge-split destination.
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.studioArtifact.identifier,
            visibility: .all
        ) { completion in
            completion(data, nil)
            return nil
        }
    }
    provider.suggestedName = artifact.title
    return provider
}

/// The pane created by an edge drop uses the same equal-width reset as the
/// live group layout. Keeping the preview calculation beside the drag contract
/// makes the outline match the final pane instead of being a generic edge cue.
enum StudioCenterTabSplitPreviewSizing {
    static func newPaneWidth(
        totalWidth: CGFloat,
        currentGroupCount: Int,
        dividerWidth: CGFloat,
        maximumGroupCount: Int = StudioCenterTabGroups.maximumGroupCount
    ) -> CGFloat {
        let nextGroupCount = currentGroupCount + 1
        guard currentGroupCount > 0,
              nextGroupCount <= maximumGroupCount else { return 0 }
        let usableWidth = totalWidth - CGFloat(nextGroupCount - 1) * dividerWidth
        return max(0, usableWidth / CGFloat(nextGroupCount))
    }

    /// The most one edge split zone may claim while a source is being dragged.
    ///
    /// A dragged source already has a destination inside every pane — Chat
    /// attaches it to the conversation, Reader opens it — so the edge zones
    /// have to leave the pane under the pointer a center band of its own. Sized
    /// to the pane they would create, the leading and trailing zones together
    /// cover the entire center area whenever there is a single group, which
    /// left a source dropped on Chat no way to reach Chat: the edge destination
    /// took every drop and opened a Reader beside it instead.
    static let minimumSourceEdgeZoneWidth: CGFloat = 22
    static let maximumSourceEdgeZoneWidth: CGFloat = 96
    static let sourceEdgeZoneFraction: CGFloat = 0.12

    static func sourceEdgeZoneWidth(totalWidth: CGFloat) -> CGFloat {
        min(
            max(totalWidth * sourceEdgeZoneFraction, minimumSourceEdgeZoneWidth),
            maximumSourceEdgeZoneWidth
        )
    }

    /// Whether the drag in flight carries something the pane under the pointer
    /// takes itself, so the edge zones must stay a gutter: a source, or a Doc
    /// or Site record. A Docs or Sites row's drag also names its pane, but the
    /// record rides along, so it counts as content; a bare pane drag, a chat
    /// drag, or a tab-strip drag does not.
    static func dragCarriesPaneContent(
        draggedArticleCount: Int,
        draggedArtifactID: Bool,
        draggedSessionID: Bool,
        draggingTab: Bool
    ) -> Bool {
        guard !draggedSessionID, !draggingTab else { return false }
        return draggedArticleCount > 0 || draggedArtifactID
    }
}
