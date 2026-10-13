import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - Shared chrome

private enum StudioOverlayMetrics {
    static let margin: CGFloat = 24
    static let centeredWidth: CGFloat = 980
    static let centeredHeightFraction: CGFloat = 0.88
    static let minWidth: CGFloat = 520
    static let minHeight: CGFloat = 380
}

enum StudioMovableOverlay {
    static func offsetXKey(for storageID: String) -> String {
        "studio.movableOverlay.\(storageID).offsetX"
    }

    static func offsetYKey(for storageID: String) -> String {
        "studio.movableOverlay.\(storageID).offsetY"
    }

    static func clampedOffset(
        _ offset: CGSize,
        panelSize: CGSize,
        containerSize: CGSize,
        anchorCenter: CGPoint,
        margin: CGFloat = StudioOverlayMetrics.margin
    ) -> CGSize {
        let halfW = panelSize.width / 2
        let halfH = panelSize.height / 2
        let centerX = anchorCenter.x + offset.width
        let centerY = anchorCenter.y + offset.height

        let clampedCenterX = min(
            max(centerX, margin + halfW),
            max(margin + halfW, containerSize.width - margin - halfW)
        )
        let clampedCenterY = min(
            max(centerY, margin + halfH),
            max(margin + halfH, containerSize.height - margin - halfH)
        )

        return CGSize(
            width: offset.width + (clampedCenterX - centerX),
            height: offset.height + (clampedCenterY - centerY)
        )
    }
}

private struct StudioOverlayDragHandle: View {
    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 36, height: 4)
            Spacer(minLength: 0)
        }
        .frame(height: 18)
        .contentShape(Rectangle())
        .cursor(.openHand)
        .help("Drag to move")
    }
}

/// Centered glass panel used by movable utility overlays.
struct StudioCenteredOverlayChrome<Content: View>: View {
    let storageID: String
    let title: String
    let systemImage: String
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content

    @AppStorage private var storedOffsetX: Double
    @AppStorage private var storedOffsetY: Double
    @State private var dragOffset: CGSize = .zero

    init(
        storageID: String,
        title: String,
        systemImage: String,
        onDismiss: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.storageID = storageID
        self.title = title
        self.systemImage = systemImage
        self.onDismiss = onDismiss
        self.content = content
        _storedOffsetX = AppStorage(wrappedValue: 0, StudioMovableOverlay.offsetXKey(for: storageID))
        _storedOffsetY = AppStorage(wrappedValue: 0, StudioMovableOverlay.offsetYKey(for: storageID))
    }

    var body: some View {
        GeometryReader { geo in
            let available = CGSize(
                width: max(StudioOverlayMetrics.minWidth, geo.size.width - StudioOverlayMetrics.margin * 2),
                height: max(StudioOverlayMetrics.minHeight, geo.size.height - StudioOverlayMetrics.margin * 2)
            )
            let size = CGSize(
                width: min(available.width, StudioOverlayMetrics.centeredWidth),
                height: available.height * StudioOverlayMetrics.centeredHeightFraction
            )
            let anchorCenter = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let persistedOffset = CGSize(width: storedOffsetX, height: storedOffsetY)
            let totalOffset = CGSize(
                width: persistedOffset.width + dragOffset.width,
                height: persistedOffset.height + dragOffset.height
            )
            let panelCenter = CGPoint(
                x: anchorCenter.x + totalOffset.width,
                y: anchorCenter.y + totalOffset.height
            )

            ZStack {
                Color.black.opacity(0.24)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onDismiss)
                panel(size: size, dragGesture: dragGesture(
                    panelSize: size,
                    containerSize: geo.size,
                    anchorCenter: anchorCenter,
                    persistedOffset: persistedOffset
                ))
                .frame(width: size.width, height: size.height)
                .position(panelCenter)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onExitCommand(perform: onDismiss)
    }

    private func dragGesture(
        panelSize: CGSize,
        containerSize: CGSize,
        anchorCenter: CGPoint,
        persistedOffset: CGSize
    ) -> some Gesture {
        // Global space: the header moves with the panel while dragging, so local
        // translations feed back into the offset and jitter.
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                dragOffset = value.translation
            }
            .onEnded { value in
                let clamped = StudioMovableOverlay.clampedOffset(
                    CGSize(
                        width: persistedOffset.width + value.translation.width,
                        height: persistedOffset.height + value.translation.height
                    ),
                    panelSize: panelSize,
                    containerSize: containerSize,
                    anchorCenter: anchorCenter
                )
                storedOffsetX = Double(clamped.width)
                storedOffsetY = Double(clamped.height)
                dragOffset = .zero
            }
    }

    private func panel<G: Gesture>(size: CGSize, dragGesture: G) -> some View {
        let shell = RoundedRectangle(cornerRadius: ReviewGlassStyle.shellCornerRadius, style: .continuous)
        return VStack(spacing: 0) {
            header(dragGesture: dragGesture)
            Divider()
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background { shell.fill(ReviewGlassStyle.contentBackdrop) }
        .reviewGlassSurface(
            in: shell,
            tint: ReviewGlassStyle.silverTint,
            fallbackMaterial: .regularMaterial,
            fallbackBorder: Color.primary.opacity(0.10),
            shadowColor: Color.black.opacity(0.18),
            shadowRadius: 32,
            shadowY: 14
        )
        .clipShape(shell)
    }

    private func header<G: Gesture>(dragGesture: G) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .zoomedSystemFont(size: 14, weight: .semibold)
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .zoomedSystemFont(size: 15, weight: .semibold)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .cursor(.openHand)
            .help("Drag to move")

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.hoverWash(in: Circle()))
            .help("Close (Esc)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Settings overlay

private struct DismissSettingsOverlayKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    /// Closes the Settings overlay, for a row inside it that opens something
    /// in the window behind (a source, a notebook, a chat).
    var dismissSettingsOverlay: () -> Void {
        get { self[DismissSettingsOverlayKey.self] }
        set { self[DismissSettingsOverlayKey.self] = newValue }
    }
}

/// Equatable on `initialPane` only: StudioView rebuilds this value on every one
/// of its own body evaluations (the `onDismiss` closure is freshly allocated
/// each time, defeating SwiftUI's automatic diffing), which re-evaluated the
/// entire Settings subtree — NavigationStack, all panes — on every unrelated
/// Studio invalidation. That repeated full-tree rebuild is what stalled the
/// main thread (see ui-stall samples from 2026-07-15). The dismiss closure
/// only forwards to StudioView state setters, so identity-by-pane is safe.
struct SettingsOverlay: View, Equatable {
    @Environment(StudioViewModel.self) private var vm
    let initialPane: SettingsPane?
    let onDismiss: () -> Void

    static func == (lhs: SettingsOverlay, rhs: SettingsOverlay) -> Bool {
        lhs.initialPane == rhs.initialPane
    }

    /// A team's settings are their own surface, titled after the team the
    /// way the account menu's entry is ("Mitochondria Settings").
    private var isTeamScope: Bool { SettingsScope(pane: initialPane) == .team }

    private var title: String {
        guard isTeamScope else { return "Settings" }
        return vm.activeTeam.map { "\($0.name) Settings" } ?? "Team Settings"
    }

    var body: some View {
        StudioCenteredOverlayChrome(
            storageID: "settings",
            title: title,
            systemImage: isTeamScope ? "person.2.badge.gearshape" : "gearshape",
            onDismiss: onDismiss
        ) {
            SettingsView(initialPane: initialPane)
                .id(initialPane)
                .environment(\.dismissSettingsOverlay, onDismiss)
        }
    }
}

// MARK: - Plan your day?

/// "Plan your day?", each morning today's calendar holds nothing the learner
/// planned (`PlanTheDay`): in the navigation rail's footer, over the Now chip,
/// or in the window's bottom-left corner while the rail is hidden.
///
/// A card rather than a sheet, and more than a notification (product owner,
/// 2026-09-18: "notifications that show up in the corner of the screen and i
/// get to dismiss them"; 2026-09-27: "a popup notification"). It stood in the
/// window's top-right corner until the product owner (2026-09-28): "plan your day
/// notification should show up maybe in the bottom left? maybe better than
/// popups". Down there it sits beside the chip that says how the day stands,
/// and covers nothing. It waits until it is answered instead of timing out
/// like a banner, and takes neither the keyboard nor the window: no
/// `.keyboardShortcut`, since a card nobody asked for must not claim Return
/// or Escape for the whole window. The close glyph is "not today". An event
/// added to today's calendar by any route answers it too, and the card goes.
/// Its one action, Plan in Chat, opens the chat that writes the day into the
/// Mac's Calendar, in the window the card is in.
struct PlanTheDayCard: View {
    enum Style {
        /// In flow in the rail's footer, the rail's width, tinted like the
        /// footer's credits warning rather than floating over it.
        case rail
        /// Floating in the window's bottom-left corner, for a window whose
        /// rail is hidden.
        case floating
        /// In flow inside the bell's popover (the inbox): the rail's
        /// look, and the close glyph really dismisses.
        case tray

        var isCompact: Bool { self != .floating }
    }

    /// The day the question stands for (`DayModel.planTheDayAsk`).
    let day: String
    let style: Style

    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    @Environment(\.cornerNoticeReadMark) private var readMark
    private let model = DayModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: style.isCompact ? StudioDesign.Spacing.small : StudioDesign.Spacing.medium) {
            HStack(alignment: .top, spacing: StudioDesign.Spacing.small) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(PlanTheDay.title)
                        .zoomedSystemFont(size: style.isCompact ? 12.5 : 13, weight: .semibold)
                    Text(PlanTheDay.detail)
                        .zoomedSystemFont(size: style.isCompact ? 11.5 : 12)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // The window turns text selection on everywhere. The card's
                // words are read, not copied, and a right-click on them must
                // reach the card's own menu.
                .textSelection(.disabled)
                Spacer(minLength: 0)
                CornerCardClose(
                    style: style,
                    kind: .planTheDay,
                    dismissHelp: "Not today",
                    identifier: "studio.plantheday.dismiss"
                ) { model.answerPlanTheDay() }
            }
            HStack(spacing: StudioDesign.Spacing.small) {
                Spacer(minLength: 0)
                planInChatButton
            }
        }
        .cornerCardChrome(style)
        .contextMenu {
            if let readMark {
                CornerNoticeReadMenuItem(mark: readMark)
                Divider()
            }
            Button("Don't Ask Again") { model.stopAskingToPlanTheDay() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("studio.plantheday")
    }

    private var planInChatButton: some View {
        CornerCardAction(title: "Plan in Chat", identifier: "studio.plantheday.chat", prominent: true) {
            model.answerPlanTheDay()
            vm.inWindow(windowState) {
                vm.requestPlanDayChat(request: ReviewSlashCommandParser.planDayRequest(day))
            }
        }
    }
}

// MARK: - Cards to check

/// "Cards to check · 14 from 3 sources you finished": the cards ForeverLM
/// drafted in the background from what the learner finished wait in To
/// Check (`CardsToCheckNudge`; docs/memory-design.md, "Drafting in the
/// background"). A sibling of "Plan your day?" in its place — the rail's
/// footer, or the bottom-left corner of a window whose rail is hidden — and
/// never beside it: one corner card at a time, and this one waits for that
/// one. Like it, it takes neither the keyboard nor the window. Go Through
/// Them opens To Check over every notebook in this window (its menu, in the
/// other window); the close glyph is "later", asked again tomorrow while
/// drafts still wait; Don't Ask Again turns `memory.draft_nudges` off.
struct CardsToCheckCard: View {
    /// "14 from 3 sources you finished · 2 more sources to come".
    let detail: String
    let style: PlanTheDayCard.Style

    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    @Environment(\.cornerNoticeReadMark) private var readMark

    var body: some View {
        VStack(alignment: .leading, spacing: style.isCompact ? StudioDesign.Spacing.small : StudioDesign.Spacing.medium) {
            HStack(alignment: .top, spacing: StudioDesign.Spacing.small) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(CardsToCheckNudge.title)
                        .zoomedSystemFont(size: style.isCompact ? 12.5 : 13, weight: .semibold)
                    Text(detail)
                        .zoomedSystemFont(size: style.isCompact ? 11.5 : 12)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Read, not copied, and a right-click on the words must reach
                // the card's own menu.
                .textSelection(.disabled)
                Spacer(minLength: 0)
                CornerCardClose(
                    style: style,
                    kind: .cardsToCheck,
                    dismissHelp: "Later",
                    identifier: "studio.cardsToCheck.dismiss"
                ) { vm.putOffCardsToCheck() }
            }
            HStack(spacing: StudioDesign.Spacing.small) {
                Spacer(minLength: 0)
                CornerCardAction(title: CardsToCheckNudge.goThroughTitle, identifier: "studio.cardsToCheck.goThrough", prominent: true) {
                    vm.goThroughDraftedCards(in: windowState)
                }
            }
        }
        .cornerCardChrome(style)
        .contextMenu {
            if let readMark {
                CornerNoticeReadMenuItem(mark: readMark)
                Divider()
            }
            // Go Through Them opens in this window; the other one is a
            // right-click away, as for every opener.
            OtherWindowMenuItem(.cardsToCheck(notebookID: nil))
            Divider()
            Button("Don't Ask Again") { vm.stopCardsToCheckNudges() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("studio.cardsToCheck")
    }
}

// MARK: - Room for the library update

/// Whether the library update waits for disk space, for the corner card. The
/// store open that finds no room for its rollback copy (§13.3 step 1) runs on
/// the storage actor and records it in `LibraryUpgradeSpace`; this model reads
/// it at first use and on every change, so the card shows whichever comes first.
@MainActor
@Observable
final class StoreUpgradeSpaceNotice {
    static let shared = StoreUpgradeSpaceNotice()

    private(set) var message: String?
    private var isDismissed = false
    @ObservationIgnored private var observer: NSObjectProtocol?

    /// The card's line, until the learner closes it for this launch.
    var visibleMessage: String? { isDismissed ? nil : message }

    private init() {
        refresh()
        observer = NotificationCenter.default.addObserver(forName: LibraryUpgradeSpace.didChange, object: nil, queue: .main) { _ in
            Task { @MainActor in StoreUpgradeSpaceNotice.shared.refresh() }
        }
    }

    func refresh() {
        message = LibraryUpgradeSpace.current.map(LibraryUpgradeSpace.message(for:))
    }

    func dismiss() {
        isDismissed = true
    }
}

/// "Free up 6.2 GB on this Mac so ForeverLM can finish updating your library."
/// The update keeps a copy of the library first, and this launch found no room
/// for it, so the library stays as it was, fully usable, until there is. One
/// line and a close glyph that hides it for this launch: freeing space is the
/// learner's to do, and the next launch tries again. First of the corner cards
/// when it shows, since it is about the library itself.
struct StoreUpgradeSpaceCard: View {
    let message: String
    let style: PlanTheDayCard.Style

    @Environment(\.cornerNoticeReadMark) private var readMark

    var body: some View {
        HStack(alignment: .top, spacing: StudioDesign.Spacing.small) {
            Text(message)
                .zoomedSystemFont(size: style.isCompact ? 12 : 12.5, weight: .medium)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.disabled)
            Spacer(minLength: 0)
            CornerCardClose(
                style: style,
                kind: .storeUpgradeSpace,
                dismissHelp: "Hide until next launch",
                identifier: "studio.storeUpgradeSpace.dismiss"
            ) { StoreUpgradeSpaceNotice.shared.dismiss() }
        }
        .cornerCardChrome(style)
        .cornerNoticeReadMenu(readMark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("studio.storeUpgradeSpace")
    }
}

// MARK: - Moving the library to the new iCloud store

/// The generation-2 activation's progress for the corner card (docs/cloudkit-schema-design.md §13.3 step 3).
/// The storage actor runs the activation (`ActivationStatus`); this model reads it at first use and on
/// every change.
@MainActor
@Observable
final class ActivationNotice {
    static let shared = ActivationNotice()

    private(set) var phase = ActivationStatus.shared.current
    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: ActivationStatus.didChange, object: nil, queue: .main) { _ in
            Task { @MainActor in ActivationNotice.shared.phase = ActivationStatus.shared.current }
        }
    }

    /// The card's lines while the library is moving or waits for an answer; nil when there is nothing to
    /// say.
    var card: (title: String, detail: String?)? {
        switch phase {
        case .moving(let step, let total, let text):
            return ("Moving your library to the new iCloud store (step \(step) of \(total))", "\(text). You can read your library, but not change it, until this ends.")
        case .asking:
            return ("Your old iCloud library does not look like this Mac's", "Open Settings, Data & Privacy, iCloud to choose what to do.")
        case .idle, .preparing, .failed, .done:
            return nil
        }
    }
}

/// "Moving your library to the new iCloud store (step 3 of 5)": the library is readable and refuses
/// writes for the few minutes the catch-up takes (a `full` activation). No close glyph: it ends by itself.
struct ActivationCard: View {
    let title: String
    let detail: String?
    let style: PlanTheDayCard.Style

    @Environment(\.cornerNoticeReadMark) private var readMark

    var body: some View {
        HStack(alignment: .top, spacing: StudioDesign.Spacing.small) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .zoomedSystemFont(size: style.isCompact ? 12 : 12.5, weight: .medium)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .zoomedSystemFont(size: 11, weight: .regular)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.disabled)
            Spacer(minLength: 0)
            // It ends by itself, so there is nothing to dismiss: the glyph
            // only tucks it into the bell.
            if style != .tray {
                CornerCardClose(
                    style: style,
                    kind: .libraryMove,
                    dismissHelp: "",
                    identifier: "studio.libraryMove.hide"
                ) {}
            }
        }
        .cornerCardChrome(style)
        .cornerNoticeReadMenu(readMark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("studio.libraryMove")
    }
}

// MARK: - The inbox (Codex's Activity)

/// What the strip's bell lists beside the chats: the corner cards, which also
/// stand in the corner, and the notices only the bell holds. One inbox, as
/// Codex's Activity is (docs/codex-shell-plan.md, Track 4): the Space's own
/// bell for teammates' requests went into it on 2026-10-13.
enum CornerNoticeKind: String, CaseIterable, Identifiable {
    /// Corner cards, in the order the corner shows them: one card at a time,
    /// the first that is showing.
    case libraryMove, storeUpgradeSpace, planTheDay, cardsToCheck
    /// Teammates asking for sources this library holds (docs/teams-design.md,
    /// decision 14), answered here with Share or Decline.
    case shareRequests
    /// Plugins whose connection is gone and must be signed in again.
    case pluginReconnect
    var id: String { rawValue }

    /// Whether this kind can stand in the corner; the others are the bell's
    /// alone, so a notice of theirs is never "in view already".
    var isCornerCard: Bool {
        switch self {
        case .libraryMove, .storeUpgradeSpace, .planTheDay, .cardsToCheck: return true
        case .shareRequests, .pluginReconnect: return false
        }
    }

    /// What a notice of this kind is about right now, for its read mark: a
    /// mark holds while the notice says nothing it did not say when marked.
    /// A new day's "Plan your day?" is news, and so are cards from a source
    /// the pile did not hold then, or a new day for the pile, which the card
    /// itself asks about daily; a pile that shrinks is not, as for the
    /// morning-after banner (`CardsToCheckBanner.Ledger`). A new teammate's
    /// request is news, and so is another plugin losing its connection.
    @MainActor
    func subject(
        planDay: String?,
        cardsToCheck pile: CardsToCheckNudge.Pile?,
        shareRequestIDs: Set<String> = [],
        reconnectPlugins: Set<String> = [],
        now: Date = Date()
    ) -> Set<String> {
        switch self {
        case .libraryMove:
            if case .asking = ActivationNotice.shared.phase { return ["asking"] }
            return ["moving"]
        case .storeUpgradeSpace:
            return ["space"]
        case .planTheDay:
            return planDay.map { [$0] } ?? []
        case .cardsToCheck:
            return (pile?.sourceIDs ?? []).union(["day:" + MemoryReviewGoal.dayKey(for: now)])
        case .shareRequests:
            return shareRequestIDs
        case .pluginReconnect:
            return reconnectPlugins
        }
    }
}

/// What each notice is about at one moment: the inputs of
/// `CornerNoticeKind.subject`, read once per draw.
struct InboxSubjects {
    let planDay: String?
    let cardsToCheck: CardsToCheckNudge.Pile?
    let shareRequestIDs: Set<String>
    let reconnectPlugins: Set<String>

    @MainActor
    func subject(_ kind: CornerNoticeKind) -> Set<String> {
        kind.subject(
            planDay: planDay,
            cardsToCheck: cardsToCheck,
            shareRequestIDs: shareRequestIDs,
            reconnectPlugins: reconnectPlugins
        )
    }
}

/// Which corner cards the learner tucked away, and which notices they marked
/// read. A tucked card leaves the corner and waits in the bell above the
/// account (product owner, 2026-10-09), until what it is about is answered;
/// the next launch shows it in the corner again. An unread notice in the bell
/// lights it (product owner, 2026-10-10: "should be able to mark things as
/// read"): read, it stays listed, quieter, and the bell goes dark, without
/// the card's own answer (Not today, Later) being given for it. Read marks
/// survive a relaunch in this Mac's defaults (Track 4), and a card read for
/// what it says now stays out of the corner after one too.
@MainActor
@Observable
final class CornerNoticeTray {
    static let shared = CornerNoticeTray(defaults: .standard)

    /// The read marks: each kind's raw value to what it was about when it
    /// was marked. This Mac's alone (`SyncedPreferenceKeys.excluded`).
    nonisolated static let readMarksKey = "notifications.readMarks.v1"

    private(set) var tucked: Set<CornerNoticeKind> = []
    /// What each kind was about when it was marked read (`CornerNoticeKind.subject`).
    private(set) var read: [CornerNoticeKind: Set<String>] = [:]
    /// Where the marks are kept; nil keeps them for this run only (a test's tray).
    @ObservationIgnored private let defaults: UserDefaults?

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        let stored = defaults?.dictionary(forKey: Self.readMarksKey) as? [String: [String]] ?? [:]
        for (raw, subject) in stored {
            if let kind = CornerNoticeKind(rawValue: raw) { read[kind] = Set(subject) }
        }
    }

    func isTucked(_ kind: CornerNoticeKind) -> Bool { tucked.contains(kind) }
    func tuck(_ kind: CornerNoticeKind) { tucked.insert(kind) }

    func isRead(_ kind: CornerNoticeKind, subject: Set<String>) -> Bool {
        guard let marked = read[kind] else { return false }
        return subject.isSubset(of: marked)
    }

    /// Whether a card stands in the corner: not tucked this launch, and not
    /// read for what it says now.
    func showsInCorner(_ kind: CornerNoticeKind, subject: Set<String>) -> Bool {
        !tucked.contains(kind) && !isRead(kind, subject: subject)
    }

    /// Read is seen: the card leaves the corner as well, as a tucked one
    /// does. The mark is what the notice says now, so the stored mark never
    /// outgrows it.
    func markRead(_ kind: CornerNoticeKind, subject: Set<String>) {
        read[kind] = subject
        tucked.insert(kind)
        store()
    }

    /// Whether the bell wears its dot: an unread chat, or an unread notice
    /// that is not in view already — one only the bell holds, or a card
    /// tucked out of the corner. A dot, never a count.
    func lightsBell(unread kinds: [CornerNoticeKind], hasUnreadChats: Bool) -> Bool {
        hasUnreadChats || kinds.contains { !$0.isCornerCard || tucked.contains($0) }
    }

    /// Unread again: it lights the bell, and stays out of the corner.
    func markUnread(_ kind: CornerNoticeKind) {
        read[kind] = nil
        store()
    }

    private func store() {
        guard let defaults else { return }
        let marks = Dictionary(uniqueKeysWithValues: read.map { ($0.key.rawValue, $0.value.sorted()) })
        defaults.set(marks, forKey: Self.readMarksKey)
    }
}

extension StudioViewModel {
    /// The plugins whose connection is gone and must be signed in again, for
    /// the bell: X's session that cannot be refreshed, and YouTube's lost
    /// grant (set by the sync that met it, cleared by the next that gets
    /// through). The same states their pages call "Reconnect needed".
    var pluginsNeedingReconnect: [PluginPage] {
        var pages: [PluginPage] = []
        if isXOAuthSignedIn, xPluginNeedsReauth { pages.append(.x) }
        if youtubePluginNeedsReconnect { pages.append(.youtube) }
        return pages
    }

    /// What every notice is about now (`InboxSubjects`).
    func inboxSubjects(planDay: String?) -> InboxSubjects {
        InboxSubjects(
            planDay: planDay,
            cardsToCheck: cardsToCheckPile,
            shareRequestIDs: Set(fulfillableShareRequests.map(\.request.id)),
            reconnectPlugins: Set(pluginsNeedingReconnect.map(\.rawValue))
        )
    }
}

/// A card's read mark, set only on the notices the bell lists: their tint and
/// their Mark as Read / Mark as Unread item read it.
struct CornerNoticeReadMark {
    let kind: CornerNoticeKind
    let subject: Set<String>
    let isRead: Bool

    @MainActor
    func toggle() {
        withAnimation(.snappy(duration: 0.2)) {
            if isRead {
                CornerNoticeTray.shared.markUnread(kind)
            } else {
                CornerNoticeTray.shared.markRead(kind, subject: subject)
            }
        }
    }
}

private struct CornerNoticeReadMarkKey: EnvironmentKey {
    static let defaultValue: CornerNoticeReadMark? = nil
}

extension EnvironmentValues {
    /// The read mark of the bell's notice this view is in; nil for a card in
    /// the corner or the rail's footer.
    var cornerNoticeReadMark: CornerNoticeReadMark? {
        get { self[CornerNoticeReadMarkKey.self] }
        set { self[CornerNoticeReadMarkKey.self] = newValue }
    }
}

/// Mark as Read / Mark as Unread, in a notice's menu in the bell.
private struct CornerNoticeReadMenuItem: View {
    let mark: CornerNoticeReadMark

    var body: some View {
        Button {
            mark.toggle()
        } label: {
            if mark.isRead {
                Label("Mark as Unread", systemImage: "circle")
            } else {
                Label("Mark as Read", systemImage: "checkmark.circle")
            }
        }
    }
}

private extension View {
    /// The read item as the card's whole menu, for a card with no menu of its
    /// own; a card in the corner gets none.
    @ViewBuilder
    func cornerNoticeReadMenu(_ mark: CornerNoticeReadMark?) -> some View {
        if let mark {
            contextMenu { CornerNoticeReadMenuItem(mark: mark) }
        } else {
            self
        }
    }
}

/// A corner card's close glyph. In the corner it hides the card into the
/// bell; inside the bell it is the card's own answer ("Not today", "Later").
private struct CornerCardClose: View {
    let style: PlanTheDayCard.Style
    let kind: CornerNoticeKind
    let dismissHelp: String
    let identifier: String
    let dismiss: () -> Void

    var body: some View {
        let help = style == .tray ? dismissHelp : "Hide to Activity"
        Button {
            if style == .tray {
                dismiss()
            } else {
                withAnimation(.snappy(duration: 0.2)) { CornerNoticeTray.shared.tuck(kind) }
            }
        } label: {
            Image(systemName: "xmark")
                .zoomedSystemFont(size: 10, weight: .semibold)
                .frame(width: 22, height: 22)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.hoverWash(in: Circle(), inset: 0, opacity: 0.12))
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier(identifier)
        // Centre the glyph on the title's first line rather than on the top
        // of its line box.
        .padding(.top, -3)
    }
}

/// The bell above the account: the one inbox, Codex's Activity. It lists the
/// chats that need attention — unread ones (`ChatReadMarks`) and running
/// ones — then teammates' requests, plugins to reconnect and every corner card
/// that is waiting, tucked or not. `kinds` is what is waiting in this window.
/// Its dot is anything unread that is not in view already (a card still in
/// the corner is): an unread chat, a notice only the bell holds, a tucked
/// card. A dot, never a count.
struct NotificationCenterButton: View {
    let kinds: [CornerNoticeKind]
    let planDay: String?
    let cardsToCheckDetail: String?

    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    @State private var isShown = false

    var body: some View {
        let tray = CornerNoticeTray.shared
        let subjects = vm.inboxSubjects(planDay: planDay)
        let unread = kinds.filter { !tray.isRead($0, subject: subjects.subject($0)) }
        let unreadChats = InboxChats.listed(vm: vm).unread
        let lightsDot = tray.lightsBell(unread: unread, hasUnreadChats: !unreadChats.isEmpty)
        let unreadCount = unread.count + unreadChats.count
        Button { isShown.toggle() } label: {
            Image(systemName: "bell")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .overlay(alignment: .topTrailing) {
                    if lightsDot {
                        Circle().fill(Color.accentColor).frame(width: 7, height: 7).offset(x: 3, y: -2)
                    }
                }
                .frame(width: 36, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 7, inset: 0))
        .railTooltip("Activity")
        .accessibilityLabel("Activity")
        .accessibilityValue(unreadCount == 0 ? "Nothing new" : "\(unreadCount) unread")
        .accessibilityIdentifier("rail.notifications")
        .popover(isPresented: $isShown, arrowEdge: .trailing) {
            NotificationCenterList(
                kinds: kinds,
                planDay: planDay,
                cardsToCheckDetail: cardsToCheckDetail,
                close: { isShown = false }
            )
            .environment(vm)
            .environment(windowState)
        }
    }
}

/// The chats the bell lists: those this Mac marks unread and those running in
/// any window (`ChatReadMarks`), the unread first, newest first in each, of
/// the chats the open library lists.
enum InboxChats {
    @MainActor
    static func listed(vm: StudioViewModel) -> (unread: [ReviewSessionRecord], running: [ReviewSessionRecord]) {
        let marks = ChatReadMarks.shared
        let unreadIDs = marks.unreadSessionIDs
        let runningIDs = marks.runningSessionIDs
        guard !unreadIDs.isEmpty || !runningIDs.isEmpty else { return ([], []) }
        let sessions = vm.reviewSessionLinks
            .filter { unreadIDs.contains($0.id) || runningIDs.contains($0.id) }
            .sorted { $0.createdAt > $1.createdAt }
        return (
            sessions.filter { unreadIDs.contains($0.id) && !runningIDs.contains($0.id) },
            sessions.filter { runningIDs.contains($0.id) }
        )
    }
}

/// The bell's popover, Codex's Activity: the chats that need attention, then
/// the requests, the plugins to reconnect and the cards, each with its read
/// mark, and Mark All as Read while anything is unread. Its own view, so a
/// mark redraws it in place.
private struct NotificationCenterList: View {
    let kinds: [CornerNoticeKind]
    let planDay: String?
    let cardsToCheckDetail: String?
    let close: () -> Void

    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState

    var body: some View {
        let tray = CornerNoticeTray.shared
        let subjects = vm.inboxSubjects(planDay: planDay)
        let marks = kinds.map { kind in
            let subject = subjects.subject(kind)
            return CornerNoticeReadMark(kind: kind, subject: subject, isRead: tray.isRead(kind, subject: subject))
        }
        let unread = marks.filter { !$0.isRead }
        let chats = InboxChats.listed(vm: vm)
        let isEmpty = marks.isEmpty && chats.unread.isEmpty && chats.running.isEmpty
        VStack(alignment: .leading, spacing: StudioDesign.Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: StudioDesign.Spacing.small) {
                Text("Activity")
                    .zoomedSystemFont(size: 12.5, weight: .semibold)
                    .textSelection(.disabled)
                Spacer(minLength: 0)
                if !unread.isEmpty || !chats.unread.isEmpty {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            for mark in unread { tray.markRead(mark.kind, subject: mark.subject) }
                            ChatReadMarks.shared.markAllRead()
                        }
                    } label: {
                        Text("Mark All as Read")
                            .zoomedSystemFont(size: 11, weight: .medium)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, StudioDesign.Spacing.xSmall)
                            .padding(.vertical, 2)
                    }
                    .buttonStyle(.hoverWash(cornerRadius: StudioDesign.Radius.control, inset: 0))
                    .accessibilityIdentifier("rail.notifications.markAllRead")
                }
            }
            if isEmpty {
                Text("Nothing needs attention")
                    .zoomedSystemFont(size: 12.5)
                    .foregroundStyle(.secondary)
                    .textSelection(.disabled)
                    .padding(.vertical, StudioDesign.Spacing.small)
            }
            if !chats.unread.isEmpty || !chats.running.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(chats.unread) { session in
                        InboxChatRow(session: session, isRunning: false) { open(session) }
                    }
                    ForEach(chats.running) { session in
                        InboxChatRow(session: session, isRunning: true) { open(session) }
                    }
                }
            }
            ForEach(marks, id: \.kind) { mark in
                notice(mark.kind)
                    .environment(\.cornerNoticeReadMark, mark)
            }
        }
        .padding(StudioDesign.Spacing.medium)
        .frame(width: 320, alignment: .leading)
    }

    /// Opens a chat in this window, as its row in the sidebar does.
    private func open(_ session: ReviewSessionRecord) {
        close()
        vm.inWindow(windowState) { vm.requestResumeReviewSession(session.id) }
    }

    @ViewBuilder
    private func notice(_ kind: CornerNoticeKind) -> some View {
        switch kind {
        case .libraryMove:
            if let card = ActivationNotice.shared.card {
                ActivationCard(title: card.title, detail: card.detail, style: .tray)
            }
        case .storeUpgradeSpace:
            if let message = StoreUpgradeSpaceNotice.shared.visibleMessage {
                StoreUpgradeSpaceCard(message: message, style: .tray)
            }
        case .planTheDay:
            if let planDay {
                PlanTheDayCard(day: planDay, style: .tray)
            }
        case .cardsToCheck:
            if let cardsToCheckDetail {
                CardsToCheckCard(detail: cardsToCheckDetail, style: .tray)
            }
        case .shareRequests:
            let requests = vm.fulfillableShareRequests
            if requests.count > 1 {
                HStack {
                    Spacer(minLength: 0)
                    CornerCardAction(title: "Share All", identifier: "inbox.shareRequests.shareAll") {
                        if SharingRightsRow.needsAsking { close() }
                        SharingRightsPrompt.shared.askIfNeeded {
                            Task { await vm.fulfilAllShareRequests() }
                        }
                    }
                    .help("Copy every requested source you hold into the team that asked, files included")
                }
            }
            ForEach(requests, id: \.request.id) { item in
                ShareRequestNoticeCard(item: item, close: close)
            }
        case .pluginReconnect:
            ForEach(vm.pluginsNeedingReconnect, id: \.self) { page in
                PluginReconnectNoticeCard(page: page, close: close)
            }
        }
    }
}

/// One chat in the bell, as its sidebar row draws it: Codex's dot while it
/// is unread, a spinner while it runs. A click opens it in this window; its
/// menu marks it read or unread.
private struct InboxChatRow: View {
    let session: ReviewSessionRecord
    let isRunning: Bool
    let open: () -> Void

    @State private var hovering = false

    private var title: String {
        session.title.isEmpty
            ? "Untitled chat"
            : MemoryReviewSession.displayTitle(storedTitle: session.title, sessionID: session.id)
    }

    var body: some View {
        let isUnread = ChatReadMarks.shared.isUnread(session.id)
        Button(action: open) {
            HStack(spacing: 8) {
                Group {
                    if isRunning {
                        ProgressView()
                            .controlSize(.mini)
                    } else if isUnread {
                        RailUnreadDot()
                    }
                }
                .frame(width: 14)
                Text(title)
                    .zoomedSystemFont(size: 12.5)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.disabled)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 7, inset: 0, opacity: 0.08))
        .contextMenu {
            Button {
                if isUnread {
                    ChatReadMarks.shared.markRead(session.id)
                } else {
                    ChatReadMarks.shared.markUnread(session.id)
                }
            } label: {
                Label(isUnread ? "Mark as Read" : "Mark as Unread", systemImage: isUnread ? "checkmark.circle" : "circle")
            }
        }
        .accessibilityLabel(title)
        .accessibilityValue(isRunning ? "Running" : isUnread ? "Unread" : "")
        .accessibilityHint("Opens the chat in this window")
    }
}

/// A teammate's request for a source this library holds (docs/teams-design.md,
/// decision 14): what was asked for, who asked and in which team, with
/// Decline, which closes the request for everyone, and Share, which copies
/// this Mac's source into the team. The bell is where a request is answered
/// since 2026-10-13; the Space's own bell and the Docs home's banner went.
private struct ShareRequestNoticeCard: View {
    let item: StorageService.FulfillableShareRequest
    let close: () -> Void

    @Environment(StudioViewModel.self) private var vm
    @Environment(\.cornerNoticeReadMark) private var readMark

    var body: some View {
        let request = item.request
        VStack(alignment: .leading, spacing: StudioDesign.Spacing.small) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(request.requestedByDisplayName ?? "A teammate") asked for a source you hold")
                    .zoomedSystemFont(size: 12.5, weight: .semibold)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(request.title ?? Self.host(of: request.url)) · \(vm.team(id: request.teamID)?.name ?? "Team")")
                    .zoomedSystemFont(size: 11.5)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .textSelection(.disabled)
            HStack(spacing: StudioDesign.Spacing.small) {
                Spacer(minLength: 0)
                CornerCardAction(title: "Decline", identifier: "inbox.shareRequest.decline") {
                    Task { await vm.declineShareRequest(request.id) }
                }
                CornerCardAction(title: "Share", identifier: "inbox.shareRequest.share", prominent: true) {
                    // Answering copies a source into the team: the first
                    // time, the learner affirms they may share it, in the
                    // window's sheet, which the bell's popover makes way for.
                    if SharingRightsRow.needsAsking { close() }
                    SharingRightsPrompt.shared.askIfNeeded {
                        Task { await vm.fulfilShareRequest(request.id) }
                    }
                }
                .help("Copy the source into the team that asked, file included")
            }
        }
        .cornerCardChrome(.tray)
        .cornerNoticeReadMenu(readMark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inbox.shareRequest")
    }

    static func host(of url: String) -> String {
        URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? url
    }
}

/// A plugin whose connection is gone: what stopped, and Reconnect, which opens
/// its page in the Plugins place, where it signs in again.
private struct PluginReconnectNoticeCard: View {
    let page: PluginPage
    let close: () -> Void

    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    @Environment(\.cornerNoticeReadMark) private var readMark

    private var detail: String {
        switch page {
        case .x: return "Its session ended; bookmarks have stopped syncing."
        case .youtube: return "Its connection is gone; YouTube import has stopped."
        default: return "Its connection is gone."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudioDesign.Spacing.small) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Reconnect \(page.title)")
                    .zoomedSystemFont(size: 12.5, weight: .semibold)
                Text(detail)
                    .zoomedSystemFont(size: 11.5)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .textSelection(.disabled)
            HStack(spacing: StudioDesign.Spacing.small) {
                Spacer(minLength: 0)
                CornerCardAction(title: "Reconnect", identifier: "inbox.plugin.reconnect", prominent: true) {
                    close()
                    vm.openPluginsPlace(page, in: windowState)
                }
            }
        }
        .cornerCardChrome(.tray)
        .cornerNoticeReadMenu(readMark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inbox.plugin.\(page.rawValue)")
    }
}

/// A corner card's padding, width and surface: tinted in flow in the rail's
/// footer, glass floating in the window's corner. In the bell a card marked
/// read loses the tint, so the unread ones stand out.
private struct CornerCardChrome: ViewModifier {
    let style: PlanTheDayCard.Style

    @Environment(\.cornerNoticeReadMark) private var readMark

    func body(content: Content) -> some View {
        content
            .padding(.leading, style.isCompact ? 10 : StudioDesign.Spacing.large)
            .padding(.trailing, style.isCompact ? 6 : StudioDesign.Spacing.small)
            .padding(.vertical, style.isCompact ? StudioDesign.Spacing.small : StudioDesign.Spacing.medium)
            .frame(width: style == .floating ? 320 : nil)
            .frame(maxWidth: style.isCompact ? .infinity : nil, alignment: .leading)
            .background { background }
    }

    @ViewBuilder
    private var background: some View {
        switch style {
        case .rail, .tray:
            let isRead = readMark?.isRead == true
            let tint = isRead ? Color.primary : Color.accentColor
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(tint.opacity(isRead ? 0.04 : 0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(tint.opacity(isRead ? 0.1 : 0.18))
                }
        case .floating:
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08))
                }
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        }
    }
}

private extension View {
    func cornerCardChrome(_ style: PlanTheDayCard.Style) -> some View {
        modifier(CornerCardChrome(style: style))
    }
}

/// A corner card's action, the Now chip popover's: a tinted rounded rect
/// that lights up under the pointer.
private struct CornerCardAction: View {
    let title: String
    let identifier: String
    var prominent = false
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            Text(title)
                .zoomedSystemFont(size: 11, weight: .medium)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, StudioDesign.Spacing.small)
                .padding(.vertical, StudioDesign.Spacing.xSmall)
        }
        .buttonStyle(.hoverWash(cornerRadius: StudioDesign.Radius.control, inset: 0, opacity: 0.14))
        .background(
            RoundedRectangle(cornerRadius: StudioDesign.Radius.control, style: .continuous)
                .fill(Color.accentColor.opacity(prominent ? 0.18 : 0.1))
        )
        .accessibilityIdentifier(identifier)
    }
}
