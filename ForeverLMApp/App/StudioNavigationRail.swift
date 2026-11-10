import SwiftUI
import AppKit

/// Codex-style chat navigation rail. It is the app's primary navigation surface,
/// led by the notebooks (docs/notebooks-design.md, "The
/// rail"): Spaces, Memory and Library as icons, with Home's sidebar beside
/// them while a chat or the Reader is on screen: New chat and the Browser, the
/// Notebooks header (the Space's All list), then the Pinned and Recent
/// notebooks with their chats — a compact way in since 2026-10-03, the whole
/// catalog living in the Space (`NotebookRail`); the library's own chats; the
/// day and the account in the footer. The icon strip is always drawn, in a
/// window holding a notebook too; the sidebar toggle folds only Home's
/// sidebar.
struct StudioNavigationRail: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    @Environment(ManagedAIAccountModel.self) private var account
    @EnvironmentObject private var appUpdates: AppUpdateController
    /// Owns the selected manager and any chats still generating off screen.
    let sessionStore: StudioAssistantSessionStore
    /// The window's side chats (`StudioComparisonChatStores`).
    let comparisonChats: StudioComparisonChatStores
    let edge: HorizontalEdge
    /// The icon rail, or Home's sidebar beside it: the same view twice, so the
    /// notebooks' and chats' state and menus stay in one place.
    var style: Style = .strip
    let onOpenChatBeside: (String) -> Void
    let onOpenSettings: (SettingsPane?) -> Void
    /// The golden-ratio width for this window, computed by the root layout —
    /// the only place that can measure the whole window. Nil where no
    /// measurement exists yet; the rail then falls back to `defaultRailWidth`.
    var goldenWidth: CGFloat?
    /// Getting Started covers the window: no corner card is raised under it.
    var isGettingStarted = false

    @Environment(\.studioTitlebarBandHeight) private var titlebarBandHeight
    @Environment(\.openWindow) private var openWindow

    @State private var renamingSession: ReviewSessionRecord?
    /// The chat whose Delete… is asking first.
    @State private var deletingSession: ReviewSessionRecord?
    @State private var notebookFromChatRequest: NotebookFromChatRequest?
    @State private var renameText = ""
    /// Disclosure is local navigation state, but it persists across launches so
    /// opening Studio does not repeatedly erase the learner's rail organization.
    /// It is intentionally not a synced preference.
    @State private var expandedNotebookIDs: Set<String> = StudioNavigationRail.storedExpandedNotebookIDs()
    /// How many chats each list has drawn as the learner scrolled past its
    /// first page, keyed by list (a notebook, the loose chats or the hidden
    /// ones). Absent means the list shows one page. Window state, not a
    /// preference: a long history is something the learner digs into once,
    /// not a layout they chose.
    @State private var revealedChatCounts: [String: Int] = [:]
    @State private var showsAccountMenu = false
    @SyncedStorage(wrappedValue: "", StudioRailHiddenItems.storageKey) private var hiddenRailItemsStorage: String
    private var hiddenRailItems: StudioRailHiddenItems { StudioRailHiddenItems(storage: hiddenRailItemsStorage) }
    @SyncedStorage(wrappedValue: "", StudioRailShortcuts.storageKey) private var railShortcutsStorage: String
    private var railShortcuts: StudioRailShortcuts { StudioRailShortcuts(storage: railShortcutsStorage) }
    @SyncedStorage(wrappedValue: "", StudioStripFooterHiddenItems.storageKey) private var hiddenFooterItemsStorage: String
    /// A Space place is being dragged over the strip, which keeps it at the
    /// end of its shortcuts unless it is over one of them.
    @State private var shortcutDropIsTargeted = false
    /// The strip icon a place dragged in from the Space sidebar is over:
    /// dropped, it lands above it.
    @State private var stripDropBefore: StudioStripEntry?
    /// The order the learner dragged the strip's top icons and its footer's
    /// icons into (`StudioStripOrder`).
    @SyncedStorage(wrappedValue: "", StudioStripOrder.topStorageKey) private var stripTopOrderStorage: String
    @SyncedStorage(wrappedValue: "", StudioStripOrder.footerStorageKey) private var stripFooterOrderStorage: String
    @State private var mcpLauncher = MCPServerLauncher.shared
    @SyncedStorage(AssistantIntegrationSettings.enabledKey) private var assistantIntegrationsEnabled = true
    @SyncedStorage(AssistantIntegrationSettings.statusLightVisibleKey) private var showsMCPStatusLight = true
    /// Observed so a rename, here or on another client, redraws the footer.
    @SyncedStorage(wrappedValue: "", MacAccountUser.displayNamePreferenceKey) private var savedDisplayName: String
    @SyncedStorage(MacAccountUser.showsCompCrownPreferenceKey) private var showsCompCrown = true
    @AppStorage(PlanTheDay.settingKey) private var asksToPlanTheDay = true
    @SyncedStorage(wrappedValue: true, MemoryCardSettings.draftNudgesKey) private var showsDraftNudges: Bool
    /// What the learner's own key has spent since local midnight, in USD, read
    /// from the usage ledger each time the account menu opens. Nil until read.
    /// The name the rail shows: the stand-in while Screen record mode films.
    private var accountFullName: String? { MacAccountUser.displayedFullName(saved: savedDisplayName) }

    /// Untouched outer panels open at the same golden-ratio width. This is only
    /// the fallback for layouts that cannot measure the window; after the
    /// learner resizes this rail, its own persisted width takes precedence.
    static let defaultRailWidth: CGFloat = 360
    static let minRailWidth: CGFloat = 200
    /// High enough to clear the golden width of the widest arrangement — a
    /// single center pane on a 2560pt window wants ~705 — so the ratio is
    /// never clipped exactly where the side panels are meant to be widest.
    static let maxRailWidth: CGFloat = 720

    /// Persisted rail width; the user drags the trailing edge to resize.
    @AppStorage("studio.navigationRailWidth") private var storedRailWidth: Double = Double(Self.defaultRailWidth)
    /// Live width while the trailing edge is being dragged; nil when idle.
    @State private var draggedRailWidth: CGFloat?
    @State private var dragStartRailWidth: CGFloat?

    enum Style { case strip, homeSidebar }

    private var railWidth: CGFloat {
        if isCompact { return Self.compactRailWidth }
        return draggedRailWidth ?? Self.resolvedRailWidth(goldenDefault: goldenWidth)
    }

    /// The rail inside a notebook window: an icon strip, so the notebook's
    /// three columns — Sources, the chat and Studio, as in Gemini Notebook,
    /// which has no sidebar — take the window (product owner, 2026-10-02). Its
    /// notebook chats are in the strip's Chats menu, the chat's header and
    /// the notebook's guide.
    static let compactRailWidth: CGFloat = 52

    /// Whether this is the icon rail, which is the window's rail everywhere;
    /// the other style is Home's sidebar.
    private var isCompact: Bool { style == .strip }

    private static func clampedRailWidth(_ value: CGFloat) -> CGFloat {
        min(max(value, minRailWidth), maxRailWidth)
    }

    static let widthKey = "studio.navigationRailWidth"

    /// A width the learner dragged themselves, or nil while the rail has never
    /// been resized. Absent means the golden width is free to follow the
    /// window; a stored value is a deliberate override and outranks it.
    private static var draggedWidthPreference: CGFloat? {
        (UserDefaults.standard.object(forKey: widthKey) as? Double).map { CGFloat($0) }
    }

    /// The width this rail opens at: the learner's own if they ever dragged it,
    /// otherwise the golden width for this window.
    static func resolvedRailWidth(goldenDefault: CGFloat?) -> CGFloat {
        clampedRailWidth(draggedWidthPreference ?? goldenDefault ?? defaultRailWidth)
    }

    private var activeSessionIDs: Set<String> {
        Self.highlightedSessionIDs(
            primary: sessionStore.activeSessionID,
            comparison: nil,
            in: windowState
        ).union(comparisonChats.shownSessionIDs(in: windowState))
    }

    /// Whether the primary chat surface is on screen in this window: the Chat
    /// tab is the active tab of some pane, or the chat is popped out into its
    /// own window. Selecting Docs or Notebooks in a pane replaces Chat as that
    /// pane's active tab, and the rail follows: the destination row takes the
    /// highlight and the chat row gives it up, so the rail never shows a chat
    /// as selected while nothing on screen is that chat.
    static func isChatVisible(layout: StudioCenterTabGroups, chatPoppedOut: Bool) -> Bool {
        chatPoppedOut || layout.groups.contains { $0.activeTab == .chat }
    }

    /// The chats whose rail rows carry the selection. A store's chat counts
    /// only while it is showing: the primary store's while Chat is an active
    /// tab or popped out, the comparison store's while its "Open Beside" pane
    /// is the active tab of a pane in this window's layout. Both stores keep
    /// their chat after its surface is hidden so bringing it back is cheap,
    /// and without this gate a hidden chat's row stayed highlighted with
    /// nothing showing it.
    /// Whether the primary chat is on screen in `windowState`.
    static func isChatVisible(in windowState: StudioWindowState) -> Bool {
        return isChatVisible(layout: windowState.centerTabGroups, chatPoppedOut: windowState.isChatPoppedOut)
    }

    /// The highlighted chats of `windowState`.
    static func highlightedSessionIDs(
        primary: String?,
        comparison: String?,
        in windowState: StudioWindowState
    ) -> Set<String> {
        return highlightedSessionIDs(
            primary: primary,
            comparison: comparison,
            layout: windowState.centerTabGroups,
            chatPoppedOut: windowState.isChatPoppedOut
        )
    }

    static func highlightedSessionIDs(
        primary: String?,
        comparison: String?,
        layout: StudioCenterTabGroups,
        chatPoppedOut: Bool = false
    ) -> Set<String> {
        var ids = Set<String>()
        if let primary, isChatVisible(layout: layout, chatPoppedOut: chatPoppedOut) {
            ids.insert(primary)
        }
        if let comparison,
           layout.groups.contains(where: { $0.activeTab == .secondaryChat }) {
            ids.insert(comparison)
        }
        return ids
    }

    var body: some View {
        Group {
            switch style {
            case .strip: compactRail
            case .homeSidebar: fullRail
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: appUpdates.phase)
        .animation(.easeInOut(duration: 0.2), value: account.creditsAreEmpty)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: DayModel.shared.planTheDayAsk)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: vm.cardsToCheckPile)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: vm.cardsToCheckIsPutOff)
        .frame(width: railWidth)
        .background(railBackground)
        .overlay(alignment: edge == .leading ? .trailing : .leading) {
            if !isCompact {
                railResizeHandle
            }
        }
        .task {
            await vm.loadTeams()
            await vm.loadLearningGoals()
            await vm.loadReviewSessionLinks()
            reconcileExpandedNotebooks()
        }
        // An accepted invitation and a roster change both happen outside the
        // view model; the switcher's list has to follow them.
        .onReceive(NotificationCenter.default.publisher(for: TeamSharingService.teamRosterDidChange)) { note in
            Task {
                await vm.loadTeams()
                if let teamID = note.object as? String { await vm.refreshTeamMembers(teamID: teamID) }
            }
        }
        .onChange(of: expandedNotebookIDs) { _, ids in
            PreferenceStore.set(ids.sorted(), forKey: Self.expandedNotebookIDsKey)
            NotebookSidebarSync.setExpanded(ids)
        }
        // The folds the rail keeps in `@SyncedStorage` redraw themselves when a
        // remote change lands; this one is a `Set` seeded once into `@State`, so
        // it has to be reseeded explicitly or the other Mac's change would not
        // show until the next launch — the difference `PreferenceStore` warns
        // about for exactly this shape of reader.
        .onReceive(NotificationCenter.default.publisher(for: PreferenceStore.didChangeRemotely)) { note in
            let changed = note.userInfo?[PreferenceStore.changedKeysKey] as? Set<String>
            guard changed?.contains(Self.expandedNotebookIDsKey) ?? true else { return }
            let stored = Self.storedExpandedNotebookIDs()
            if stored != expandedNotebookIDs { expandedNotebookIDs = stored }
        }
        .onChange(of: activeSessionIDs) { _, _ in
            expandNotebooksContainingActiveChats()
        }
        .onChange(of: vm.notebooks.map(\.id)) { _, _ in
            reconcileExpandedNotebooks()
        }
        // Codex's Rename chat: the title in a field, Save.
        .alert(
            "Rename Chat",
            isPresented: Binding(
                get: { renamingSession != nil },
                set: { if !$0 { renamingSession = nil } }
            )
        ) {
            TextField("Add a title…", text: $renameText)
            Button("Cancel", role: .cancel) { renamingSession = nil }
            Button("Save") {
                if let session = renamingSession {
                    let title = renameText
                    Task { await vm.renameReviewSession(session.id, title: title) }
                }
                renamingSession = nil
            }
        }
        // Delete asks first, as Codex's does and Home's list does; until
        // 2026-10-13 the rail's Delete was the one hard delete that did not.
        .confirmationDialog(
            "Delete \u{2018}\(deletingSession.map(railChatTitle) ?? "this chat")\u{2019}?",
            isPresented: Binding(
                get: { deletingSession != nil },
                set: { if !$0 { deletingSession = nil } }
            ),
            titleVisibility: .visible,
            presenting: deletingSession
        ) { session in
            Button("Delete", role: .destructive) {
                deleteSession(session)
                deletingSession = nil
            }
        } message: { _ in
            Text("The chat and its transcript are deleted. This can\u{2019}t be undone; Hide keeps it out of the list instead.")
        }
        .newNotebookFromChat($notebookFromChatRequest, vm: vm, window: windowState)
    }

    /// A chat's name as its row shows it.
    private func railChatTitle(_ session: ReviewSessionRecord) -> String {
        session.title.isEmpty
            ? "Untitled chat"
            : MemoryReviewSession.displayTitle(storedTitle: session.title, sessionID: session.id)
    }

    /// The window's rail, Codex's: a + for a new chat, Spaces, Memory,
    /// Library and Plugins as icons, then the places the learner kept there
    /// (`StudioRailShortcuts`), from the ⋯ or by dragging a Space sidebar row
    /// onto the strip, then the ⋯ with every other place; then
    /// the day's calendar glyph, whose popover is the schedule, and the
    /// account. The notebooks and the chats are Home's sidebar (`fullRail`),
    /// which shows beside a chat or the Reader; "Plan your day?" and "Cards
    /// to check" are in its footer, or in the window's corner where Home's
    /// sidebar is not showing.
    @ViewBuilder
    private var compactRail: some View {
        let shortcuts = railShortcuts.shown(listsCanvases: vm.listsCanvases)
        let litShortcut = shortcuts.first(where: isShowing)
        let topEntries = stripTopEntries(shortcuts: shortcuts)
        let footerEntries = stripFooterEntries
        let dragged = StudioDragVisibility.shared.draggedStripEntry
        // The place a drag from the Space sidebar would keep at the end,
        // drawn there until the drop: over an icon, a line above that one
        // shows where it lands instead. A strip icon's own drag moves the
        // icon itself.
        let landing = shortcutDropIsTargeted && stripDropBefore == nil && dragged == nil
            ? StudioDragVisibility.shared.draggedRailShortcut
            : nil
        VStack(spacing: 4) {
            // The strip's rows and the kept places, in the learner's order.
            // The kept places stand with the rows, above the ⋯, with no line
            // between: under a line they read as a second, stray group
            // (product owner, 2026-11-07: "those new icons shouldn't show up
            // under that like dividing bar").
            ForEach(topEntries) { entry in
                topStripButton(entry, litShortcut: litShortcut)
                    // A kept one dragged to the end shows there instead; the
                    // icon being dragged stays dimmed where it would land.
                    .opacity(entry == dragged || entry == landing.map(StudioStripEntry.shortcut) ? 0.35 : 1)
                    .onDrop(
                        of: [.studioStripEntry, .studioRailShortcut],
                        delegate: stripDropDelegate(target: entry, footer: false, shown: topEntries)
                    )
                    .overlay(alignment: .top) {
                        if stripDropBefore == entry, dragged == nil,
                           StudioDragVisibility.shared.draggedRailShortcut.map(StudioStripEntry.shortcut) != entry {
                            Capsule()
                                .fill(Color.primary.opacity(0.5))
                                .frame(width: 24, height: 2)
                                .offset(y: -3)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
            }
            if let landing {
                RailGlyph(systemImage: landing.systemImage, assetImage: landing.assetImage)
                    .background(StudioSelectionBackground(isSelected: true, isHovered: false))
                    .opacity(0.6)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
            // Always drawn, last: it is also the way back for a hidden row,
            // its menu ending with Show in Sidebar.
            RailMoreButton(
                places: StudioRailShortcut.offered(listsCanvases: vm.listsCanvases)
                    .filter { !shortcuts.contains($0) },
                open: openShortcut
            )
            Spacer(minLength: 0)
            if account.creditsAreEmpty, !vm.isScreenRecordModeActive {
                Button { onOpenSettings(.aiUsage) } label: {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.orange)
                        .frame(width: 36, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hoverWash(cornerRadius: 7, inset: 0))
                .railTooltip("Credits used up")
                .accessibilityLabel("Credits used up")
                .transition(.opacity)
            }
            // The update offer's own place: Sparkle leaves announcing an update
            // to the rail whenever the rail is shown (`pillOwnsOffer`), so the
            // strip has to carry it too, or a notebook window never offers one.
            if appUpdates.isUpdateAvailable {
                RailUpdateButton(updateController: appUpdates, isCompact: true)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
            // The footer's icons, in the learner's order.
            ForEach(footerEntries) { entry in
                if case .footer(let item) = entry {
                    footerStripButton(item)
                        .contextMenu {
                            Button {
                                hiddenFooterItemsStorage = StudioStripFooterHiddenItems(storage: hiddenFooterItemsStorage)
                                    .setting(item, hidden: true)
                                    .storage
                            } label: {
                                Label("Hide \(item.title)", systemImage: "eye.slash")
                            }
                            .accessibilityIdentifier("studio.navigation.hide.\(item.rawValue)")
                            RailItemVisibilityMenu()
                        }
                        .opacity(entry == dragged ? 0.35 : 1)
                        .onDrag {
                            StudioDragVisibility.shared.begin(stripEntry: entry)
                            return NSItemProvider().carryingStripEntry(entry)
                        }
                        .onDrop(
                            of: [.studioStripEntry],
                            delegate: stripDropDelegate(target: entry, footer: true, shown: footerEntries)
                        )
                }
            }
        }
        .padding(.bottom, 8)
        .task { BackgroundWorkMonitor.shared.start() }
        // The strip is in every window, always: it reports the window's chats
        // to the unread marks.
        .background {
            ChatActivityReporter(sessionStore: sessionStore, comparisonChats: comparisonChats)
        }
        .padding(.top, titlebarBandHeight == nil && edge == .leading ? 48 : StudioDesign.Spacing.medium)
        .frame(maxWidth: .infinity)
        // A Space sidebar row dropped anywhere on the strip is kept at the
        // end of its shortcuts, its glyph alone, as the ⋯'s Show in Sidebar
        // keeps one.
        .contentShape(Rectangle())
        .onDrop(
            of: [.studioStripEntry, .studioRailShortcut],
            delegate: stripDropDelegate(target: nil, footer: false, shown: topEntries)
        )
        .animation(.easeInOut(duration: 0.16), value: landing)
        .animation(.easeInOut(duration: 0.16), value: topEntries)
        .animation(.easeInOut(duration: 0.16), value: footerEntries)
    }

    /// The strip's rows the learner has not hidden and the places kept
    /// there, in the order the learner dragged them into.
    private func stripTopEntries(shortcuts: [StudioRailShortcut]) -> [StudioStripEntry] {
        let shown = hiddenRailItems.railItems().map(StudioStripEntry.row) + shortcuts.map(StudioStripEntry.shortcut)
        return StudioStripOrder(storage: stripTopOrderStorage).arranged(shown)
    }

    /// The footer's icons the learner has not hidden, MCP's only while its
    /// light is shown, in the order the learner dragged them into.
    private var stripFooterEntries: [StudioStripEntry] {
        let hidden = StudioStripFooterHiddenItems(storage: hiddenFooterItemsStorage)
        let shown = StudioStripFooterItem.allCases
            .filter { !hidden.contains($0) }
            .filter { $0 != .mcp || showsMCPStatusLight }
            .map(StudioStripEntry.footer)
        return StudioStripOrder(storage: stripFooterOrderStorage).arranged(shown)
    }

    @ViewBuilder
    private func topStripButton(_ entry: StudioStripEntry, litShortcut: StudioRailShortcut?) -> some View {
        switch entry {
        case .row(.space): spaceButton(compact: true, yieldsTo: litShortcut != nil)
        case .row(.memory): memoryButton(compact: true)
        case .row(.library): libraryButton(compact: true)
        case .row(.plugins): pluginsButton(compact: true)
        case .row(.home): homeButton()
        case .row(.newChat), .row(.browser), .footer: EmptyView()
        case .shortcut(let shortcut): shortcutButton(shortcut, isSelected: shortcut == litShortcut)
        }
    }

    @ViewBuilder
    private func footerStripButton(_ item: StudioStripFooterItem) -> some View {
        switch item {
        // Voice mode, one click from anywhere (product owner, 2026-11-08:
        // "I should just be able to open voice mode ... in the bottom left
        // where those icons are"): the assistant that knows the plan, the
        // calendar and recent work (`MacRealtimeAssistant`).
        case .voice: railVoiceButton
        // What an AI app set the app's models to do, an explainer, an
        // import: the app's logo, over the paid work (product owner, 2026-10-13).
        case .work: StudioWorkButton()
        // The OpenRouter button: paid work running in the background, one
        // click from its progress and a Stop (product owner, 2026-10-08),
        // and under it what has run and the key (2026-10-15).
        case .aiUsage:
            BackgroundWorkButton(
                monitor: BackgroundWorkMonitor.shared,
                onOpenSettings: { onOpenSettings($0) }
            )
        case .day: DayNowChip(style: .rail, compact: true, iconOnly: true)
        // Every corner card that is waiting, the ones tucked away included.
        case .notifications:
            NotificationCenterButton(
                kinds: activeNoticeKinds,
                planDay: DayModel.shared.planTheDayAsk,
                cardsToCheckDetail: vm.cardsToCheckDetail
            )
        // MCP's state and Settings, one click each beside the account
        // (product owner, 2026-11-08: "why not put settings and mcp
        // status also here in the bottom left as icons"). The account
        // menu keeps its rows for both.
        case .mcp: railMCPButton
        case .settings: railSettingsButton
        case .account: accountMenuButton(compact: true)
        }
    }

    private var railVoiceButton: some View {
        Button {
            MacRealtimeVoice.startAssistant()
        } label: {
            RailGlyph(systemImage: "waveform")
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 7, inset: 0))
        .railTooltip("Talk to ForeverLM")
        .accessibilityLabel("Talk to ForeverLM")
        .accessibilityIdentifier("studio.navigation.voice")
    }

    /// Where a drag over the strip lands. A strip icon's own drag moves it
    /// within its group as it passes over the others; a place dragged in
    /// from the Space sidebar is kept above the icon it is dropped on, or
    /// at the end of the top group.
    private func stripDropDelegate(target: StudioStripEntry?, footer: Bool, shown: [StudioStripEntry]) -> StudioStripDropDelegate {
        StudioStripDropDelegate(
            target: target,
            acceptsPlaces: !footer,
            footer: footer,
            reorder: { dragged in
                guard let target, dragged.isFooter == footer else { return }
                let keys = shown.map(\.key)
                withAnimation(.easeInOut(duration: 0.16)) {
                    if footer {
                        stripFooterOrderStorage = StudioStripOrder(storage: stripFooterOrderStorage)
                            .moving(dragged.key, to: target.key, shown: keys)
                            .storage
                    } else {
                        stripTopOrderStorage = StudioStripOrder(storage: stripTopOrderStorage)
                            .moving(dragged.key, to: target.key, shown: keys)
                            .storage
                    }
                }
            },
            hoverPlace: { isOver in
                if let target {
                    if isOver {
                        stripDropBefore = target
                    } else if stripDropBefore == target {
                        stripDropBefore = nil
                    }
                } else {
                    shortcutDropIsTargeted = isOver
                }
            },
            keepPlace: { providers in
                keepDroppedShortcut(providers, before: target, shown: shown)
            }
        )
    }

    /// Keeps the place a drop carries on the strip, above `next` or at the
    /// end of the top group.
    private func keepDroppedShortcut(
        _ providers: [NSItemProvider],
        before next: StudioStripEntry?,
        shown: [StudioStripEntry]
    ) -> Bool {
        StudioRailShortcut.loadDropped(from: providers) { shortcut in
            let entry = StudioStripEntry.shortcut(shortcut)
            withAnimation(.easeInOut(duration: 0.16)) {
                if !railShortcuts.contains(shortcut) {
                    railShortcutsStorage = railShortcuts.setting(shortcut, shown: true).storage
                }
                stripTopOrderStorage = StudioStripOrder(storage: stripTopOrderStorage)
                    .placing(entry.key, before: next?.key, shown: shown.map(\.key))
                    .storage
            }
        }
    }

    /// The notices with something to say right now: the corner cards, tucked
    /// or not, and what only the bell holds. What the bell lists beside the
    /// chats that need attention.
    private var activeNoticeKinds: [CornerNoticeKind] {
        var kinds: [CornerNoticeKind] = []
        if asksToPlanTheDay, DayModel.shared.planTheDayAsk != nil { kinds.append(.planTheDay) }
        if vm.cardsToCheckDetail != nil,
           vm.showsCardsToCheckCard(
               in: windowState,
               isGettingStarted: isGettingStarted,
               asksToPlanTheDay: false,
               showsNudges: showsDraftNudges
           ) {
            kinds.append(.cardsToCheck)
        }
        // What only the bell holds: teammates' requests, and plugins to
        // reconnect.
        if !vm.fulfillableShareRequests.isEmpty { kinds.append(.shareRequests) }
        if !vm.pluginsNeedingReconnect.isEmpty { kinds.append(.pluginReconnect) }
        return kinds
    }


    /// The notebooks the rail has rows for, by id: the active ones, and an
    /// archived one this window holds.
    private func railNotebooksByID(_ rail: NotebookRail) -> [String: LearningGoalRecord] {
        let ids = Set(rail.notebookIDs)
        return Dictionary(
            vm.allNotebooks.filter { ids.contains($0.id) }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    @ViewBuilder
    private var fullRail: some View {
        let hiddenItems = hiddenRailItems
        VStack(spacing: 0) {
            // Each top row can be taken off the rail from its own menu; with
            // every one hidden the block goes too, so the notebooks move up
            // rather than sitting under an empty band.
            let topItems = hiddenItems.sidebarItems()
            if !topItems.isEmpty {
                VStack(spacing: 2) {
                    ForEach(topItems) { item in
                        switch item {
                        case .newChat: newChatButton()
                        case .browser: browserButton()
                        case .home, .space, .memory, .library, .plugins: EmptyView()
                        }
                    }
                }
                    .padding(.horizontal, StudioDesign.Spacing.small)
                    // With no titlebar band (fullscreen) the sidebar toggle sits
                    // in-flow over the rail's top-left corner; start the rail's
                    // content below that row instead of underneath the toggle.
                    .padding(.top, titlebarBandHeight == nil && edge == .leading ? 48 : StudioDesign.Spacing.medium)
                    .padding(.bottom, StudioDesign.Spacing.small)
            }

            ScrollView {
                // Notebooks is a clickable section header that opens the
                // Space's All list, with the Pinned and Recent notebooks
                // beneath it (`NotebookRail`): a compact way in, the whole
                // catalog living in the Space (product owner, 2026-10-03, of ~52
                // notebooks: "is it even still good design to have all these
                // notebooks in the left sidebar as well?"). The collections'
                // rows went with the Notebooks home (2026-10-09): All groups
                // by collection. A notebook's
                // chats live directly beneath its row; library chats and
                // chats whose notebook has no row here — archived, neither
                // pinned nor recent — remain in the Chats section so nothing
                // becomes unreachable.
                // The notebook this window holds: another window's never
                // lights a notebook here.
                let scopedNotebook = vm.railScopedNotebook(in: windowState)
                let rail = vm.notebookRail(in: windowState)
                let notebooks = railNotebooksByID(rail)
                let railNotebooks = rail.notebookIDs.compactMap { notebooks[$0] }
                let chatGroups = vm.reviewSessionGroups(for: railNotebooks)
                // A pinned chat leaves its notebook's chats or the loose ones
                // for Pinned, under the pinned notebooks, as Codex's pinned
                // chats leave their project (`ChatPins`).
                let chats = vm.splittingPinnedChats(
                    byNotebookID: chatGroups.byNotebookID,
                    outsideNotebooks: chatGroups.outsideNotebooks
                )
                let unreadChatIDs = ChatReadMarks.shared.unreadSessionIDs
                // Hidden chats leave every list above and sit folded under the
                // loose chats, whichever Notebook they are filed in.
                let hiddenChats = vm.hiddenReviewSessions(for: railNotebooks)
                // One pass over the live managers for the whole rail; asking
                // per row registered every row against every manager's
                // generation flags and re-scanned the managers rows × flips
                // times per turn.
                let runningSessionIDs = sessionStore.runningSessionIDs
                    .union(comparisonChats.runningSessionIDs)

                // Chat rows carry menus, drag support, and hover state. Building the
                // entire history eagerly made SwiftUI materialize every row and its
                // nested notebook menu before the rail could draw; with a moderately
                // sized history that produced a multi-gigabyte display list and a
                // permanent beachball. Keep only the viewport's rows alive.
                LazyVStack(alignment: .leading, spacing: 2) {
                    // The header opens the Space's All list, where every
                    // notebook is listed: in a window holding a notebook it
                    // opens as one more tab of the notebook's panes. Home's sidebar
                    // shows only while the window is not on the Space, so the
                    // header is never the lit row.
                    RailSectionHeaderButton(
                        title: "Notebooks",
                        identifier: "studio.navigation.notebooks"
                    ) {
                        vm.inWindow(windowState) { vm.showSpaceAll(in: windowState) }
                    }
                    .onDrag {
                        StudioDragVisibility.shared.begin(centerTab: .artifacts)
                        return studioCenterTabDragProvider(for: .artifacts)
                    }
                    .contextMenu {
                        // The Courses list: every course, which lives in no
                        // notebook.
                        Section("Courses") {
                            Button("Open Courses", systemImage: "graduationcap") {
                                vm.inWindow(windowState) { vm.showSpaceTab(.courses) }
                            }
                            Button("Open Courses Beside", systemImage: "rectangle.split.2x1") {
                                vm.inWindow(windowState) {
                                    vm.openCenterTabBeside(.courses)
                                    vm.openCoursesListInReader()
                                }
                            }
                            OpenStudioDestinationInOtherWindowMenu(
                                destination: .courses,
                                currentWindowState: windowState,
                                openNewWindow: { openWindow(id: "studio") }
                            )
                        }
                        // The Space: every page, site, picture, canvas, list,
                        // notebook and course. Goals and Ideas are the chat's
                        // to show (`SpaceTab`).
                        Section("Space") {
                            Button("Open Space", systemImage: "square.grid.2x2") {
                                vm.inWindow(windowState) { vm.showSpaceAll(in: windowState) }
                            }
                            Button("Open Space Beside", systemImage: "rectangle.split.2x1") {
                                vm.inWindow(windowState) {
                                    vm.openCenterTabBeside(.artifacts)
                                    vm.openArtifactsInReader()
                                }
                            }
                            OpenStudioDestinationInOtherWindowMenu(
                                destination: .artifacts,
                                currentWindowState: windowState,
                                openNewWindow: { openWindow(id: "studio") }
                            )
                        }
                        // The Notebooks header cannot be hidden, so this menu is
                        // the one route back that survives hiding every row
                        // above it.
                        Divider()
                        RailItemVisibilityMenu()
                    }

                    // Both placeholders wait for the first library load: until
                    // then an empty list means "still reading", and "No notebooks
                    // yet" would greet a learner whose notebooks are seconds away.
                    if railNotebooks.isEmpty, vm.hasCompletedInitialQueueLoad {
                        RailPlaceholderRow(
                            text: vm.archivedNotebooks.isEmpty ? "No notebooks yet" : "No active notebooks",
                            indent: 8
                        )
                    }

                    if !rail.pinnedIDs.isEmpty || !chats.pinned.isEmpty {
                        RailSectionHeader(title: "Pinned")
                        ForEach(rail.pinnedIDs.compactMap { notebooks[$0] }) { notebook in
                            notebookRow(
                                notebook,
                                scopedNotebook: scopedNotebook,
                                chatGroups: chats.byNotebookID,
                                runningSessionIDs: runningSessionIDs,
                                unreadChatIDs: unreadChatIDs
                            )
                        }
                        // The pinned chats, in the learner's order: a drop on
                        // one moves the dragged pin to its place.
                        let pinnedIDs = chats.pinned.map(\.id)
                        ForEach(chats.pinned) { session in
                            chatRow(
                                session,
                                siblingIDs: pinnedIDs,
                                runningSessionIDs: runningSessionIDs,
                                indent: 0,
                                reorder: { dragged in
                                    withAnimation(.easeInOut(duration: 0.16)) {
                                        vm.reorderPinnedChat(from: dragged, to: session.id, listed: pinnedIDs)
                                    }
                                }
                            )
                        }
                    }

                    // The last few worked in, and the notebook this window last
                    // left when it is neither pinned nor recent, so going back
                    // to it stays one click.
                    let recent = (rail.recentIDs + [rail.openNotebookID].compactMap { $0 }).compactMap { notebooks[$0] }
                    if !recent.isEmpty {
                        RailSectionHeader(title: "Recent")
                        ForEach(recent) { notebook in
                            notebookRow(
                                notebook,
                                scopedNotebook: scopedNotebook,
                                chatGroups: chats.byNotebookID,
                                runningSessionIDs: runningSessionIDs,
                                unreadChatIDs: unreadChatIDs
                            )
                        }
                    }

                    // The library's own chats. The header's + starts one: a
                    // library chat, which leaves a notebook the window holds
                    // (the chat-home rule), where New chat above makes a
                    // notebook chat there. The + shows while the pointer is
                    // over the header (product owner, 2026-10-06: "cleaner and fewer
                    // buttons"), and the header's menu keeps it for the
                    // keyboard. Scoped to this rail's window: the request must
                    // land in the Chat pane beside this rail, not in whichever
                    // window's pane happens to run its task first.
                    RailSectionHeader(
                        title: "Chats",
                        isExpanded: isChatsExpanded,
                        toggleExpanded: {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                isChatsExpanded.toggle()
                            }
                        }
                    ) {
                        vm.inWindow(windowState) { vm.requestBlankReviewChat() }
                    }
                    .contextMenu {
                        Button("New Library Chat", systemImage: "plus") {
                            vm.inWindow(windowState) { vm.requestBlankReviewChat() }
                        }
                        Divider()
                        // Hidden chats are hidden: no row in the rail says
                        // they exist. The learner who hid them knows where to
                        // look, and this menu is the one route to them
                        // (product owner, 2026-09-20).
                        if !hiddenChats.isEmpty {
                            Button(
                                isHiddenChatsExpanded
                                    ? "Hide Hidden Chats"
                                    : "Show Hidden Chats (\(hiddenChats.count))",
                                systemImage: isHiddenChatsExpanded ? "eye.slash" : "eye"
                            ) {
                                withAnimation(.easeInOut(duration: 0.16)) {
                                    isHiddenChatsExpanded.toggle()
                                    if isHiddenChatsExpanded { isChatsExpanded = true }
                                }
                            }
                        } else {
                            Text("No hidden chats")
                        }
                    }
                    if isChatsExpanded {
                        if chatGroups.totalCount == 0 && hiddenChats.isEmpty {
                            if vm.hasCompletedInitialQueueLoad {
                                RailPlaceholderRow(
                                    text: "No chats yet",
                                    indent: 8
                                )
                            }
                        } else {
                            chatList(chats.outsideNotebooks, listID: Self.looseChatListID, runningSessionIDs: runningSessionIDs)
                            if !hiddenChats.isEmpty, isHiddenChatsExpanded {
                                hiddenChatsFold(hiddenChats, runningSessionIDs: runningSessionIDs)
                            }
                        }
                    }
                }
                .padding(.horizontal, StudioDesign.Spacing.small)
                .padding(.bottom, StudioDesign.Spacing.large)
            }

            // "Plan your day?" on a morning with nothing planned, over the
            // Now chip's place, until it is answered
            // (product owner, 2026-09-28: "maybe in the bottom left? maybe better
            // than popups"). One corner card at a time.
            // A card tucked this launch, or read for what it says now, waits
            // in the bell instead.
            let tray = CornerNoticeTray.shared
            let subjects = vm.inboxSubjects(planDay: DayModel.shared.planTheDayAsk)
            if asksToPlanTheDay, let day = DayModel.shared.planTheDayAsk,
                      tray.showsInCorner(.planTheDay, subject: subjects.subject(.planTheDay)) {
                PlanTheDayCard(day: day, style: .rail)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    /// The strip paints nothing: it stands on the window's chrome, the
    /// surface the titlebar band and the gutters are, so the traffic lights
    /// above it and the strip below them are one color, as in Codex, and the
    /// card's rounded edge is the only seam. Home's sidebar is inside the card
    /// and takes the sidebar's tone there, as the Space's sidebar does,
    /// starting under the band.
    @ViewBuilder
    private var railBackground: some View {
        if !isCompact {
            SpaceSidebarMetrics.background
        }
    }

    /// One notebook's row, Pinned or Recent, and its chats beneath it while
    /// it is unfolded.
    @ViewBuilder
    private func notebookRow(
        _ notebook: LearningGoalRecord,
        scopedNotebook: LearningGoalRecord?,
        chatGroups: [String: [ReviewSessionRecord]],
        runningSessionIDs: Set<String>,
        unreadChatIDs: Set<String>
    ) -> some View {
        let isExpanded = expandedNotebookIDs.contains(notebook.id)
        // Its chats that read as unread on this Mac: the row carries Codex's
        // dot for them while it is folded, and Mark All as Read.
        let unreadInNotebook = unreadChatIDs.isEmpty
            ? []
            : (chatGroups[notebook.id] ?? []).map(\.id).filter(unreadChatIDs.contains)
        RailNotebookRow(
            goal: notebook,
            notebookTitle: NotebookTitle(notebook.title),
            // Active means "this notebook is open" — the rail keeps
            // showing which one even after the reader column has
            // moved on to a source, so fresh chats keep adopting it.
            isActive: scopedNotebook?.id == notebook.id,
            // Selected while its notebook fills this window.
            isSelected: windowState.NotebookID == notebook.id,
            isExpanded: isExpanded,
            unreadChatIDs: unreadInNotebook,
            // A click opens the notebook in this window and shows
            // its chats; it never closes the notebook or folds
            // them — ‹ Notebooks, the notebook's ⋯ and the
            // Notebook menu close it, and the chevron folds.
            // A notebook fills its window, so there is no pane
            // to open it beside; Open in Other Window is on the
            // row's menu.
            open: {
                if !isExpanded {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        _ = expandedNotebookIDs.insert(notebook.id)
                    }
                }
                vm.inWindow(windowState) { vm.openNotebookInReader(notebook.id) }
            },
            toggleExpanded: {
                withAnimation(.easeInOut(duration: 0.16)) {
                    if isExpanded {
                        expandedNotebookIDs.remove(notebook.id)
                    } else {
                        expandedNotebookIDs.insert(notebook.id)
                    }
                }
            },
            // Open the notebook first: the fresh chat has to land
            // in it and appear beneath this row.
            newChat: {
                vm.inWindow(windowState) {
                    vm.openNotebook(notebook.id, startsNotebookChat: false)
                    vm.requestBlankReviewChat(notebookID: notebook.id)
                }
            }
        )
        if isExpanded {
            // The row already reserves an icon column. A small
            // extra inset is enough to communicate nesting
            // without pushing chat titles into a second column.
            chatList(
                chatGroups[notebook.id] ?? [],
                listID: Self.notebookChatListID(notebook.id),
                runningSessionIDs: runningSessionIDs,
                indent: 12
            )
        }
    }

    private static let expandedNotebookIDsKey = "studio.navigation.expandedProjectIDs.v1"

    /// Whether the loose chats show beneath the Chats header. Open by default
    /// so a learner who has never folded it finds the chats; it folds so a long history of chats
    /// outside Notebooks stops pushing the account row's neighbours around.
    @SyncedStorage(wrappedValue: true, "studio.navigation.chatsExpanded.v1") private var isChatsExpanded: Bool
    /// Whether the Hidden fold under Chats is open. Closed by default: a chat
    /// is hidden to be out of the way, and the fold's count says it is there.
    @SyncedStorage(wrappedValue: false, "studio.navigation.hiddenChatsExpanded.v1") private var isHiddenChatsExpanded: Bool

    private static func storedExpandedNotebookIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: expandedNotebookIDsKey) ?? [])
    }

    /// Folds are kept for every active notebook, not only those with a row
    /// now: Recent changes as the learner works, and a notebook coming back
    /// into it comes back as it was left.
    private func reconcileExpandedNotebooks() {
        let validIDs = Set(vm.notebooks.map(\.id))
        expandedNotebookIDs.formIntersection(validIDs)
        expandNotebooksContainingActiveChats()
    }

    private func expandNotebooksContainingActiveChats() {
        let railIDs = Set(vm.notebookRail(in: windowState).notebookIDs)
        for session in vm.reviewSessionLinks where activeSessionIDs.contains(session.id) {
            if MemoryReviewSession.isMemorySession(session.id) {
                // A day's review has no row in the rail; the Memory row is
                // where it is reached, and nothing unfolds.
                continue
            } else if vm.isChatPinned(session.id) {
                // Its row is in Pinned, which never folds.
                continue
            } else if let goalID = session.goalID, railIDs.contains(goalID) {
                expandedNotebookIDs.insert(goalID)
            } else {
                // Loose, or in a notebook the rail has no row for (archived,
                // neither pinned nor recent): the row lives in Chats, so an
                // active one unfolds the section the way it would a notebook.
                isChatsExpanded = true
            }
        }
    }

    /// Inner-edge grab strip that resizes the rail, drawn over the rail's own
    /// padding so it never steals clicks from row content. The visible
    /// hairline is the card's column divider, with its short stroke in the
    /// titlebar band as the panel dividers have.
    private var railResizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 8)
            .frame(maxHeight: .infinity)
            .overlay(alignment: edge == .leading ? .trailing : .leading) {
                StudioColumnHairline()
            }
            .contentShape(Rectangle())
            .cursor(.resizeLeftRight)
            .onTapGesture(count: 2) {
                // Double-click clears the override rather than writing the
                // fallback width, so the rail goes back to tracking the
                // window's golden ratio instead of freezing at 360.
                UserDefaults.standard.removeObject(forKey: Self.widthKey)
            }
            .gesture(
                // Global space: the handle moves with the rail's edge while
                // dragging, so a local-space translation would feed back into
                // itself and stutter.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartRailWidth ?? railWidth
                        dragStartRailWidth = start
                        let delta = edge == .leading ? value.translation.width : -value.translation.width
                        draggedRailWidth = Self.clampedRailWidth(start + delta)
                    }
                    .onEnded { _ in
                        if let width = draggedRailWidth {
                            storedRailWidth = Double(width)
                        }
                        dragStartRailWidth = nil
                        draggedRailWidth = nil
                    }
            )
    }

    // MARK: - New chat

    // MARK: - Library

    /// Which library the Studio shows: My Library or one team. A team is a
    /// second library, so the switch sits above every destination the rail
    /// offers; everything beneath it reloads for the chosen scope. The row
    /// carries the team's name while a team is open, so the learner is never
    /// left guessing whose sources and chats they are looking at.

    /// New chat: Home's sidebar's first row, and on the icon strip a + above
    /// Spaces (product owner, 2026-10-13: "maybe we need a 'new chat' button
    /// at the top of the left side bar as well; just a + sign"), so a chat
    /// is one click away from every place, a notebook window included.
    private func newChatButton() -> some View {
        // Highlighted only while the user is actually on a fresh/blank chat
        // (no session loaded yet) and that chat is on screen. Once a real chat
        // is open its own row carries the selection, and once Docs or Notebooks
        // has replaced Chat in its pane that row does, so the rail never shows
        // two selected items at once.
        RailButtonRow(
            title: "New chat",
            systemImage: "square.and.pencil",
            railItem: .newChat,
            isSelected: sessionStore.activeSessionID == nil
                && Self.isChatVisible(in: windowState),
            openBeside: {
                vm.inWindow(windowState) {
                    vm.openCenterTabBeside(.chat)
                    vm.requestNewChat()
                }
            },
            otherWindowDestination: .newChat,
            help: "Start a new chat",
            identifier: "studio.navigation.newChat",
            isCompact: false
        ) {
            vm.inWindow(windowState) { vm.requestNewChat() }
        }
        // Draggable like the other workspace destinations: dropped at either
        // edge of the center area it opens a fresh chat in its own pane.
        .onDrag {
            StudioDragVisibility.shared.begin(centerTab: .chat)
            return studioCenterTabDragProvider(for: .chat, startsBlankChat: true)
        }
    }

    /// Home (2026-10-16), Codex's first icon, which took the + 's place on the
    /// strip: a blank chat with Home's sidebar beside it, New chat, the
    /// notebooks and every chat. In a window holding a notebook it leaves the
    /// notebook first (`requestBlankReviewChat`), and the notebook's row
    /// brings it back. Lit while the window is on Home, the sidebar showing.
    private func homeButton() -> some View {
        RailButtonRow(
            title: StudioRailItem.home.title,
            systemImage: StudioRailItem.home.systemImage,
            railItem: .home,
            isSelected: windowState.isOnHome && !windowState.isVoiceWorkspacePresented,
            openBeside: {
                vm.inWindow(windowState) {
                    vm.openCenterTabBeside(.chat)
                    vm.requestBlankReviewChat()
                }
            },
            otherWindowDestination: .newChat,
            help: "Home: a new chat, with your notebooks and chats beside it",
            identifier: "studio.navigation.home",
            isCompact: true
        ) {
            vm.inWindow(windowState) { vm.requestBlankReviewChat() }
        }
        // Draggable like New chat: dropped at either edge of the center area
        // it opens a fresh chat in its own pane.
        .onDrag {
            StudioDragVisibility.shared.begin(centerTab: .chat, stripEntry: .row(.home))
            return studioCenterTabDragProvider(for: .chat, startsBlankChat: true).carryingStripEntry(.row(.home))
        }
    }

    /// Browser, under Memory: the web itself, in tabs, with profiles that keep
    /// separate logins. A place, so every click lands on the pane with the
    /// tabs it had; a fresh window opens on a blank tab. In a window holding a
    /// notebook it opens in a pane of the notebook's window.
    private func browserButton(compact: Bool = false) -> some View {
        RailButtonRow(
            title: "Browser",
            systemImage: "safari",
            railItem: .browser,
            isSelected: vm.visibleCenterTabs(in: windowState).contains(.browser)
                && !windowState.isVoiceWorkspacePresented,
            openBeside: {
                vm.openCenterTabBeside(.browser)
                vm.openBrowserInReader()
            },
            otherWindowDestination: .browser,
            help: "Open Browser",
            identifier: "studio.navigation.browser",
            isCompact: compact
        ) {
            vm.openBrowserInReader()
        }
        .onDrag {
            StudioDragVisibility.shared.begin(centerTab: .browser)
            return studioCenterTabDragProvider(for: .browser)
        }
    }

    /// A place since the card review (2026-10-01): the Memory pane, with
    /// today's cards across every notebook (a notebook one click away in the
    /// pane), Start Review, what is waiting to be checked, and every kept
    /// card. In a window holding a notebook it opens in the notebook's
    /// pane, still over every notebook. Only the pane's Start Review
    /// gives the window over, as only the Review mode sheet's did before.
    /// Nothing trails the label: a countdown there read as a stuck clock
    /// whenever the review was not being worked; the counts are in the help.
    private func memoryButton(compact: Bool = false) -> some View {
        RailButtonRow(
            title: "Memory",
            systemImage: MemoryReviewSession.sidebarIcon,
            railItem: .memory,
            isSelected: vm.visibleCenterTabs(in: windowState).contains(.memory)
                && !windowState.isVoiceWorkspacePresented,
            openBeside: {
                vm.inWindow(windowState) { vm.openMemoryPaneBeside() }
            },
            otherWindowDestination: .memory,
            help: memoryHelp,
            identifier: "studio.navigation.memory",
            isCompact: compact
        ) {
            vm.inWindow(windowState) { vm.openMemoryPane() }
        }
        .onDrag {
            StudioDragVisibility.shared.begin(centerTab: .memory, stripEntry: .row(.memory))
            return studioCenterTabDragProvider(for: .memory).carryingStripEntry(.row(.memory))
        }
        .onAppear { goalTracker.configure(storage: vm.storage) }
    }

    /// Spaces (2026-10-07): ChatGPT's Space, the first row of the rail since
    /// the Notebooks home went (2026-10-09), with its own sidebar beside it
    /// and every notebook and course in its All list. Lit while the Space is
    /// on one of this window's panes — its lists, the Courses list, or the
    /// global Pages and Sites. Today's daily note is a page in it (⇧⌘D opens it
    /// from the View menu). A click shows the place the window last showed.
    /// `yieldsTo`: a shortcut kept on the strip is lit for the place on
    /// screen, and the Space's row gives the light to it.
    private func spaceButton(compact: Bool = false, yieldsTo shortcutIsLit: Bool = false) -> some View {
        RailButtonRow(
            title: StudioRailItem.space.title,
            systemImage: StudioRailItem.space.systemImage,
            railItem: .space,
            isSelected: windowState.showsSpace && !shortcutIsLit && !windowState.isVoiceWorkspacePresented,
            openBeside: {
                vm.inWindow(windowState) {
                    vm.openCenterTabBeside(.artifacts)
                    vm.openArtifactsInReader()
                }
            },
            otherWindowDestination: .artifacts,
            help: "Open Spaces: your notebooks, pages, sites, pictures and ideas (⌘P)",
            identifier: "studio.navigation.space",
            isCompact: compact
        ) {
            vm.inWindow(windowState) { vm.openArtifactsInReader() }
        }
        .onDrag {
            StudioDragVisibility.shared.begin(centerTab: .artifacts, stripEntry: .row(.space))
            return studioCenterTabDragProvider(for: .artifacts).carryingStripEntry(.row(.space))
        }
    }

    /// The Library (decisions v5, 2): the whole library, every
    /// kind, laid out for managing it. A place, like Memory: a pane with its
    /// ×, Open Beside, Open in Other Window and a drag. In a window holding a
    /// notebook it leaves the notebook the way the Space does; the notebook's
    /// row below brings it back.
    private func libraryButton(compact: Bool = false) -> some View {
        RailButtonRow(
            title: "Library",
            systemImage: StudioRailItem.library.systemImage,
            railItem: .library,
            isSelected: vm.visibleCenterTabs(in: windowState).contains(.library)
                && !windowState.isVoiceWorkspacePresented,
            openBeside: {
                vm.inWindow(windowState) { vm.openCenterTabBeside(.library) }
            },
            otherWindowDestination: .library,
            help: "Open Library (⇧⌘L)",
            identifier: "studio.navigation.library",
            isCompact: compact
        ) {
            vm.inWindow(windowState) { vm.openLibraryView() }
        }
        .onDrag {
            StudioDragVisibility.shared.begin(centerTab: .library, stripEntry: .row(.library))
            return studioCenterTabDragProvider(for: .library).carryingStripEntry(.row(.library))
        }
    }

    /// Plugins (2026-10-13), Codex's grid: every plugin and its state, and a
    /// plugin's page a click away. A place like the Library: a pane with its
    /// ×, Open Beside, Open in Other Window and a drag; a click shows the
    /// list, as Codex's Plugins does, and in a window holding a notebook it
    /// leaves the notebook the way the Library does.
    private func pluginsButton(compact: Bool = false) -> some View {
        RailButtonRow(
            title: StudioRailItem.plugins.title,
            systemImage: StudioRailItem.plugins.systemImage,
            railItem: .plugins,
            isSelected: vm.visibleCenterTabs(in: windowState).contains(.plugins)
                && !windowState.isVoiceWorkspacePresented,
            openBeside: {
                vm.inWindow(windowState) { vm.openCenterTabBeside(.plugins) }
            },
            otherWindowDestination: .plugins(.directory),
            help: "Open Plugins",
            identifier: "studio.navigation.plugins",
            isCompact: compact
        ) {
            vm.openPluginsPlace(nil, in: windowState)
        }
        .onDrag {
            StudioDragVisibility.shared.begin(centerTab: .plugins, stripEntry: .row(.plugins))
            return studioCenterTabDragProvider(for: .plugins).carryingStripEntry(.row(.plugins))
        }
    }

    // MARK: - Shortcuts

    /// A place the learner kept on the strip: its glyph, lit while the
    /// window shows it, its menu taking it off again. It drags as its
    /// Space sidebar row does, so a drag up or down the strip reorders the
    /// shortcuts: a place dropped on one lands above it.
    private func shortcutButton(_ shortcut: StudioRailShortcut, isSelected: Bool) -> some View {
        RailButtonRow(
            title: shortcut.title,
            systemImage: shortcut.systemImage,
            assetImage: shortcut.assetImage,
            isSelected: isSelected,
            otherWindowDestination: otherWindowDestination(for: shortcut),
            identifier: "studio.navigation.shortcut.\(shortcut.key)",
            isCompact: true,
            removeFromRail: {
                railShortcutsStorage = StudioRailShortcuts(storage: railShortcutsStorage)
                    .setting(shortcut, shown: false)
                    .storage
            }
        ) {
            openShortcut(shortcut)
        }
        .onDrag {
            shortcut.beginDrag(onStrip: true)
            return shortcut.dragProvider().carryingStripEntry(.shortcut(shortcut))
        }
    }

    /// Whether this window shows the place: the Space on that place (its
    /// list, not a page opened from it), or the Courses pane.
    private func isShowing(_ shortcut: StudioRailShortcut) -> Bool {
        guard !windowState.isVoiceWorkspacePresented else { return false }
        let activeTabs = windowState.centerTabGroups.groups.map(\.activeTab)
        switch shortcut {
        case .place(let place):
            return activeTabs.contains(.artifacts) && windowState.spaceDestinationKey == place.key
        case .courses:
            return activeTabs.contains(.courses)
        }
    }

    /// Shows the place in this window as the Space sidebar's row does.
    private func openShortcut(_ shortcut: StudioRailShortcut) {
        vm.inWindow(windowState) {
            switch shortcut {
            case .place(let place): vm.showSpace(place, in: windowState)
            case .courses: vm.openCoursesListInReader(in: windowState)
            }
        }
    }

    private func otherWindowDestination(for shortcut: StudioRailShortcut) -> StudioWindowDestination? {
        switch shortcut {
        case .place(.pages): return .docs
        case .place(.sites): return .sites
        case .place: return nil
        case .courses: return .courses
        }
    }

    private var goalTracker: MemoryReviewEngagementTracker { MemoryReviewEngagementTracker.shared }

    private var memoryHelp: String {
        if case .done = goalTracker.state { return "Today's review is done" }
        if case .ended(let seconds) = goalTracker.state {
            let minutes = Int((seconds / 60).rounded())
            return minutes >= 1
                ? "Today's review ended after \(minutes) min"
                : "Today's review ended"
        }
        return vm.memoryCardCounts.line ?? "Nothing due today"
    }

    // MARK: - Chats

    /// A list draws this many chats, and this many more each time the
    /// learner scrolls to its end. It was ten behind a "Show 10 more" row
    /// until the product owner, on 2026-10-02: "instead of show 10 more i should just
    /// be able to scroll down and see all? also make it 20". The page still
    /// matters: a notebook keeps its whole history, and a list drawn whole
    /// would push the Chats section out of reach before anyone scrolled.
    static let chatListPageSize = 20

    static let looseChatListID = "chats"
    static let hiddenChatListID = "chats.hidden"
    static func notebookChatListID(_ notebookID: String) -> String { "notebook:\(notebookID)" }

    /// How many of a list's `total` chats the rail draws. `revealed` is the
    /// count scrolling to the list's end has reached (nil for a fresh list),
    /// and `requiredIndex` is the position of a chat that must stay visible —
    /// the open one — so selecting an old chat from Search or a deep link
    /// never lands on a row the rail then hides behind the fold.
    static func visibleChatCount(
        total: Int,
        revealed: Int?,
        requiredIndex: Int?,
        pageSize: Int = chatListPageSize
    ) -> Int {
        var count = max(revealed ?? pageSize, pageSize)
        if let requiredIndex {
            count = max(count, requiredIndex + 1)
        }
        return min(max(count, 0), max(total, 0))
    }

    /// The rows for one list of chats — a notebook's chats, the loose ones or
    /// the hidden ones — a page at a time: an empty marker after the last row
    /// drawn adds the next page when the rail's lazy stack builds it, which is
    /// as the learner scrolls it into view. Drag reordering keeps the whole
    /// list as its sibling set: a chat dropped on a visible row still lands
    /// among the same siblings whether or not the rest are drawn.
    @ViewBuilder
    private func chatList(
        _ sessions: [ReviewSessionRecord],
        listID: String,
        runningSessionIDs: Set<String>,
        indent: CGFloat = 8
    ) -> some View {
        let siblingIDs = sessions.map(\.id)
        let activeIDs = activeSessionIDs
        let visibleCount = Self.visibleChatCount(
            total: sessions.count,
            revealed: revealedChatCounts[listID],
            requiredIndex: sessions.lastIndex { activeIDs.contains($0.id) }
        )
        ForEach(sessions.prefix(visibleCount)) { session in
            chatRow(session, siblingIDs: siblingIDs, runningSessionIDs: runningSessionIDs, indent: indent)
        }
        if visibleCount < sessions.count {
            // Identified by the count it extends, so each page gets a fresh
            // marker: one that stayed on screen after a page landed (a tall
            // window) would never appear again to ask for the next.
            Color.clear
                .frame(height: 1)
                .accessibilityHidden(true)
                .id("\(listID).more.\(visibleCount)")
                .onAppear {
                    revealedChatCounts[listID] = visibleCount + Self.chatListPageSize
                }
        }
    }

    /// The chats the learner hid from the sidebar, listed beneath the loose
    /// chats only after the Chats header's menu revealed them: a hidden chat
    /// leaves no row behind, not even a count, so the rail reads as if it
    /// were gone. Once revealed, a "Hidden" marker row heads the list and
    /// folds it away again; the rows themselves offer Show, and a chat shown
    /// again returns to its notebook or the loose list.
    @ViewBuilder
    private func hiddenChatsFold(
        _ sessions: [ReviewSessionRecord],
        runningSessionIDs: Set<String>
    ) -> some View {
        RailShowMoreRow(
            title: "Hidden",
            accessibilityHint: "Fold the \(sessions.count) hidden chat\(sessions.count == 1 ? "" : "s") away",
            systemImage: "eye.slash",
            indent: 8
        ) {
            withAnimation(.easeInOut(duration: 0.16)) {
                isHiddenChatsExpanded = false
            }
        }
        .accessibilityIdentifier("studio.rail.hiddenChats")
        chatList(sessions, listID: Self.hiddenChatListID, runningSessionIDs: runningSessionIDs, indent: 12)
    }

    /// One chat's row. `reorder` replaces the list's own drop (the chats'
    /// order) where the row is in Pinned, whose drop moves a pin.
    private func chatRow(
        _ session: ReviewSessionRecord,
        siblingIDs: [String],
        runningSessionIDs: Set<String>,
        indent: CGFloat = 8,
        reorder: ((String) -> Void)? = nil
    ) -> some View {
        let isMemoryReview = MemoryReviewSession.isMemorySession(session.id)
        let isPinned = vm.isChatPinned(session.id)
        let isUnread = ChatReadMarks.shared.isUnread(session.id)
        return RailChatRow(
            sessionID: session.id,
            title: railChatTitle(session),
            // A team's snapshot is the one chat marked apart: nobody
            // continues it (docs/teams-design.md).
            systemImage: chatRowIcon(for: session),
            isSelected: activeSessionIDs.contains(session.id),
            isRunning: runningSessionIDs.contains(session.id),
            indent: indent,
            // A day's review stays under Memory wherever it is filed, so
            // offering to move it would promise a change the rail never shows.
            notebooks: MemoryReviewSession.isMemorySession(session.id) ? [] : vm.notebooks,
            // A Goal is the other home a chat can have (2026-09-20): the
            // submenu lists the open ones beneath the notebooks.
            goals: MemoryReviewSession.isMemorySession(session.id) ? [] : vm.allGoals.filter { !$0.isDone && !$0.isArchived },
            // The chats this row sits beside in the rail. Only they may be
            // dropped on it, so a reorder can never quietly refile a chat under
            // a different notebook — the notebook row's drop does that.
            siblingIDs: siblingIDs,
            displayedNotebookID: session.goalID,
            hasExplicitNotebook: session.goalID != nil,
            open: { vm.inWindow(windowState) { vm.requestResumeReviewSession(session.id) } },
            openBeside: { onOpenChatBeside(session.id) },
            moveToNotebook: { goalID in
                Task { await vm.moveReviewSession(session.id, toNotebook: goalID) }
            },
            reorder: reorder ?? { draggedSessionID in
                withAnimation(.easeInOut(duration: 0.16)) {
                    vm.reorderReviewSession(from: draggedSessionID, to: session.id)
                }
            },
            // Codex's Pin chat: a day's review is Memory's and never pins.
            isPinned: isPinned,
            togglePinned: isMemoryReview ? nil : {
                withAnimation(.easeInOut(duration: 0.16)) {
                    vm.setChatPinned(session.id, pinned: !isPinned)
                }
            },
            // Codex's dot, this Mac's: Mark as Read takes it off by hand,
            // Mark as Unread puts it on until the chat is opened again.
            isUnread: isUnread,
            toggleUnread: {
                if isUnread {
                    ChatReadMarks.shared.markRead(session.id)
                } else {
                    ChatReadMarks.shared.markUnread(session.id)
                }
            },
            rename: {
                renameText = session.title
                renamingSession = session
            },
            isHidden: session.isHidden,
            toggleHidden: {
                let hidden = !session.isHidden
                Task { await vm.setReviewSessionHidden(session.id, hidden: hidden) }
            },
            // A snapshot is already a team's, and a day's review is about the
            // learner; neither is offered to a team.
            shareWithTeam: session.isTeamSnapshot || MemoryReviewSession.isMemorySession(session.id)
                ? nil
                : { teamID in Task { await vm.shareChat(session.id, withTeam: teamID) } },
            newNotebookFromChat: session.isTeamSnapshot || MemoryReviewSession.isMemorySession(session.id)
                || vm.isActiveLibraryReadOnly
                ? nil
                : { notebookFromChatRequest = NotebookFromChatRequest(sessionID: session.id, title: session.title) },
            // Delete asks first, as Codex's does: it is the chat's fate, where
            // Hide is only the list's.
            delete: { deletingSession = session }
        )
        .onDrag { () -> NSItemProvider in
            StudioDragVisibility.shared.begin(sessionID: session.id)
            return reviewSessionDragProvider(for: ReviewSessionTransfer(from: session))
        }
    }

    /// The row's leading glyph. A transcript a team shares is a snapshot
    /// nobody continues; the pair of figures marks it apart from the
    /// learner's own chats. Every other chat draws none, as in ChatGPT's
    /// sidebar (product owner, 2026-10-06: "fewer buttons and bells and
    /// whistles"): the iPhone and CarPlay marks, the scheduled run's clock and
    /// the memory review's brain went that day. A memory review is listed
    /// under Memory, not in these lists, and a task's chat takes its task's
    /// title.
    private func chatRowIcon(for session: ReviewSessionRecord) -> String? {
        session.isTeamSnapshot ? "person.2" : nil
    }

    private func deleteSession(_ session: ReviewSessionRecord) {
        // Close first, before waiting for the storage actor. A CloudKit merge can
        // keep that actor busy for a while; leaving the selected chat active in
        // the meantime lets an in-flight response save back into the session the
        // learner just deleted.
        StudioAssistantSessionStore.deleteSessionEverywhere(session.id)
        Task {
            await vm.deleteReviewSessionLink(session.id)
        }
    }

    // MARK: - MCP and Settings

    /// MCP on the strip: its glyph with the status light on its corner, at
    /// all times, so how assistants reach this Mac is seen without opening
    /// anything; a click opens MCP settings (Billing while MCP is locked).
    private var railMCPButton: some View {
        Button {
            onOpenSettings(account.isMCPLocked ? .aiBilling : .mcp)
        } label: {
            RailGlyph(systemImage: "point.3.connected.trianglepath.dotted")
                .overlay(alignment: .bottomTrailing) {
                    mcpStatusLight
                        .scaleEffect(0.8)
                        .offset(x: -8, y: -6)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 7, inset: 0))
        .railTooltip(mcpStatusLightLabel)
        .accessibilityLabel(mcpStatusLightLabel)
        .accessibilityIdentifier("studio.navigation.mcp")
    }

    /// Settings on the strip, opening on the AI models. The account menu
    /// carries no My Settings row beside it (product owner, 2026-11-08:
    /// "settings is redundant"); with the gear hidden, ⌘, still opens it.
    private var railSettingsButton: some View {
        Button {
            onOpenSettings(nil)
        } label: {
            RailGlyph(systemImage: "gearshape")
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 7, inset: 0))
        .railTooltip("Settings")
        .accessibilityLabel("Settings")
        .accessibilityIdentifier(AccessibilityID.settingsButton)
    }

    // MARK: - Account

    /// The account control. In the icon rail (`compact`) it is the avatar
    /// alone, under the MCP and Settings icons; the menu it opens is the same.
    private func accountMenuButton(compact: Bool = false) -> some View {
        Button {
            showsAccountMenu.toggle()
        } label: {
            if compact {
                // The strip's MCP icon carries the status light beside it.
                accountAvatar(size: 24)
                    .frame(width: 36, height: 32)
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                accountMenuLabel
            }
        }
        .buttonStyle(.hoverWash(cornerRadius: 7, inset: 0))
        .modifier(RailHelpOrTooltip(text: compact ? "Account" : accountButtonHelpText, isCompact: compact))
        .accessibilityLabel("Account menu")
        .accessibilityValue(accountButtonAccessibilityValue)
        .accessibilityIdentifier(AccessibilityID.accountMenuButton)
        .popover(
            isPresented: $showsAccountMenu,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: compact ? .trailing : .bottom
        ) {
            accountMenu
        }
        .onChange(of: showsAccountMenu) { _, isShown in
            guard isShown else { return }
            // Whether usage is comped is only as fresh as the last balance fetch,
            // which is otherwise launch and Settings. Opening the menu asks again.
            if showsCompOnScreen {
                Task { await account.refresh(minimumInterval: 30, silently: true) }
            }
        }
    }

    private var accountMenuLabel: some View {
        // The avatar and the name, as ChatGPT's sidebar ends (product owner,
        // 2026-10-06: "fewer buttons and bells and whistles"). The open
        // team's badge says whose library this is, and the MCP status light
        // rides inside the button only while the connection needs attention;
        // the comp crown is the account menu's "Usage is paid for" row now.
        // Their click actions live in the menu this button opens.
        HStack(spacing: 8) {
            accountAvatar(size: 22)
            Text(MacAccountUser.leadingName(of: accountFullName) ?? "Account")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if let team = vm.activeTeam {
                activeTeamBadge(team)
                    .transition(.opacity)
            }
            if showsMCPStatusLightOnButton {
                mcpStatusLight
                    .padding(.trailing, 2)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 32)
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    /// The account menu is shaped like Claude's: who you are, then a short
    /// flat list of account actions. Which library is open is chosen in the
    /// Space sidebar, not here (product owner, 2026-10-17: "there is no team
    /// library anymore ... that is now in spaces"), and team management lives
    /// in Settings, scoped to the open team (product owner, 2026-09-08).
    private var accountMenu: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                accountAvatar(size: 30)
                Text(accountFullName ?? "Account")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)

            Divider()

            accountMenuActions
        }
        .padding(8)
        .frame(width: 232)
    }

    @ViewBuilder
    private var accountMenuActions: some View {
        // The free days' count, quietly: "29 days free left". It opens
        // Billing, where the deal is (docs/pricing-pro-design.md → The free
        // days).
        if let freeDays = account.freeDaysStatus {
            accountMenuAction(
                title: freeDays,
                systemImage: "gift",
                accessibilityIdentifier: "rail.freeDays"
            ) {
                showsAccountMenu = false
                onOpenSettings(.aiBilling)
            }
            .help("Open Billing")
        }

        if showsMCPStatusLight {
            accountMenuAction(
                title: mcpStatusLightLabel,
                icon: mcpStatusLight,
                accessibilityIdentifier: AccessibilityID.mcpStatusButton
            ) {
                showsAccountMenu = false
                // Locked, the way back to MCP is Billing, where it is paid for.
                onOpenSettings(account.isMCPLocked ? .aiBilling : .mcp)
            }
            .help(account.isMCPLocked ? "Open Billing" : "Open MCP settings")
            .accessibilityValue(mcpStatusLightLabel)
        }

        if let team = vm.activeTeam {
            accountMenuAction(
                title: "\(team.name) Settings",
                systemImage: team.canEdit ? "person.2.badge.gearshape" : "lock",
                accessibilityIdentifier: "rail.teamSettings"
            ) {
                showsAccountMenu = false
                onOpenSettings(.teamGeneral)
            }
            .help(team.canEdit ? "Open the team's settings" : "Open the team's settings (read-only library)")
        }

        accountMenuAction(
            title: "Sign Out",
            systemImage: "rectangle.portrait.and.arrow.right",
            accessibilityIdentifier: AccessibilityID.signOutButton
        ) {
            showsAccountMenu = false
            account.signOut()
        }
    }

    private func accountMenuAction(
        title: String,
        systemImage: String,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        accountMenuAction(
            title: title,
            icon: Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary),
            accessibilityIdentifier: accessibilityIdentifier,
            action: action
        )
    }

    private func accountMenuAction<Icon: View>(
        title: String,
        subtitle: String? = nil,
        icon: Icon,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(minHeight: 32)
            .padding(.vertical, subtitle == nil ? 0 : 4)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.hoverWash(cornerRadius: 7, inset: 0))
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    /// Names the open team on the account button, where the switcher now
    /// lives, so a team library is never mistaken for My Library.
    private func activeTeamBadge(_ team: TeamRecord) -> some View {
        HStack(spacing: 3) {
            Image(systemName: team.canEdit ? "person.2.fill" : "lock.fill")
                .font(.system(size: 9, weight: .semibold))
            Text(team.name)
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.accentColor.opacity(0.12), in: Capsule())
        .accessibilityHidden(true)
    }

    private func accountAvatar(size: CGFloat) -> some View {
        Text(MacAccountUser.monogram(of: accountFullName) ?? "?")
            .font(.system(size: size * 0.4, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(Color.primary.opacity(0.08), in: Circle())
            .overlay { Circle().stroke(Color.primary.opacity(0.08)) }
    }

    /// The MCP light is decoration inside the account button; the menu row that
    /// reuses it is where clicking leads to MCP settings.
    private var mcpStatusLight: some View {
        Circle()
            .fill(mcpStatusLightColor)
            .frame(width: 8, height: 8)
            .overlay {
                Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }

    // MARK: Comp

    /// The comp pays only for what goes through the proxy. With the learner's
    /// own key stored, everything the key
    /// covers goes straight to its router and is billed there, so the comp row
    /// said "Usage is paid for by ForeverLM · $0.00 used today" while the key
    /// paid for the day's chats (2026-09-27). The help text names the key instead.
    private var ownKeyPays: Bool { account.ownKey != nil }

    private var compHelpText: String {
        if let own = account.ownKey, ownKeyPays {
            return "\(own.router.billedScopeCapitalized) are billed to your \(own.router.label) account"
        }
        return "Usage is paid for by ForeverLM on this account"
    }

    /// The button's tooltip and the comp refresh on opening the menu: on for a comped account unless the learner switched the crown
    /// off, and never while screen record mode is filming (usage stays off
    /// screen). The button itself carries no crown.
    private var showsCompOnScreen: Bool {
        account.usageIsComped && showsCompCrown && !vm.isScreenRecordModeActive
    }

    private var accountButtonHelpText: String {
        var parts = ["Account menu"]
        if let team = vm.activeTeam {
            parts.append(team.canEdit ? "Team library: \(team.name)" : "Team library: \(team.name), read only")
        }
        // The tooltip is on screen too; VoiceOver's value below keeps it.
        if showsCompOnScreen { parts.append(compHelpText) }
        if showsMCPStatusLight { parts.append(mcpStatusLightLabel) }
        return parts.joined(separator: " · ")
    }

    private var accountButtonAccessibilityValue: String {
        var parts: [String] = ["Library: \(vm.activeLibraryTitle)"]
        if account.usageIsComped { parts.append(compHelpText) }
        if showsMCPStatusLight { parts.append(mcpStatusLightLabel) }
        return parts.joined(separator: ", ")
    }

    /// The light on the account button: only while assistants cannot reach
    /// this Mac — connecting (amber), offline or failed (red). Connected
    /// draws nothing (2026-10-06; it was a green dot at all times), and so
    /// do integrations the learner turned off, which is a choice rather than
    /// something to fix; `studio.showMCPStatusLight` turns it off altogether.
    /// The account menu's MCP row keeps saying how the connection stands.
    private var showsMCPStatusLightOnButton: Bool {
        guard showsMCPStatusLight else { return false }
        guard assistantIntegrationsEnabled else { return false }
        switch mcpLauncher.state {
        case .running, .servedElsewhere:
            return false
        case .starting, .settingUp, .idle, .failed:
            return true
        }
    }

    private var mcpStatusLightColor: Color {
        guard assistantIntegrationsEnabled else { return .red }
        switch mcpLauncher.state {
        // Assistants reach the library either way; the label says which Mac answers.
        case .running, .servedElsewhere:
            return .green
        case .starting, .settingUp:
            return .yellow
        case .idle, .failed:
            return .red
        }
    }

    /// While MCP is locked (the free days over, nothing paid) the connection
    /// is stopped on purpose (product owner, 2026-10-10), so the light says
    /// so rather than calling it a failure.
    private var mcpStatusLightLabel: String {
        guard assistantIntegrationsEnabled else { return "MCP disabled" }
        if account.isMCPLocked { return "MCP locked" }
        switch mcpLauncher.state {
        case .running:
            return "MCP connected"
        case .servedElsewhere:
            return "MCP served by another Mac"
        case .starting, .settingUp:
            return "MCP connecting"
        case .idle:
            return "MCP offline"
        case .failed:
            return "MCP connection failed"
        }
    }

}

