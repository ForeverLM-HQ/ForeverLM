import SwiftUI
import AppKit

// MARK: - Requests from the menu bar

extension Notification.Name {
    /// A `ShellAction` the menu bar asks the window whose id is the object to
    /// run (`ShellActionRequest.actionKey` in the user info).
    static let shellAction = Notification.Name("shellAction")
    /// Codex's Go to Chat 1–9 and Open Recent Chat 1–6, in the window whose id
    /// is the object (`ShellActionRequest.chatIndexKey`,
    /// `ShellActionRequest.recentKey`).
    static let shellGoToChat = Notification.Name("shellGoToChat")
    /// Chat › Side Chat (⌥⌘S): the side chat about the whole conversation, in
    /// the docked chat of the window whose id is the object.
    static let openThreadSideChat = Notification.Name("openThreadSideChat")
}

enum ShellActionRequest {
    static let actionKey = "action"
    static let chatIndexKey = "index"
    static let recentKey = "recent"

    @MainActor
    static func post(_ action: ShellAction, to windowID: UUID?) {
        NotificationCenter.default.post(name: .shellAction, object: windowID, userInfo: [actionKey: action.rawValue])
    }

    /// The `index`th chat (from 0) of Home's sidebar, or of the recent chats.
    @MainActor
    static func postGoToChat(_ index: Int, recent: Bool, to windowID: UUID?) {
        NotificationCenter.default.post(
            name: .shellGoToChat,
            object: windowID,
            userInfo: [chatIndexKey: index, recentKey: recent]
        )
    }
}

// MARK: - The menu bar's keys, from the shared table

extension ShellKey {
    var keyEquivalent: KeyEquivalent {
        switch key {
        case ShellKey.tab: return .tab
        case ShellKey.escape: return .escape
        case ShellKey.returnKey: return .return
        default: return KeyEquivalent(Character(key))
        }
    }

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.control) { result.insert(.control) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.command) { result.insert(.command) }
        return result
    }

    var keyboardShortcut: KeyboardShortcut {
        KeyboardShortcut(keyEquivalent, modifiers: eventModifiers)
    }
}

extension View {
    /// The menu bar's key for `action`, from `ShellAction.keys`.
    func shellShortcut(_ action: ShellAction) -> some View {
        keyboardShortcut(action.key?.keyboardShortcut)
    }
}

/// File › New Window (⌃⌘N): a Studio window. ⌘N is Codex's New Chat.
struct NewStudioWindowMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(ShellAction.newWindow.title) { openWindow(id: "studio") }
            .shellShortcut(.newWindow)
    }
}

// MARK: - The chats in Home's sidebar order

extension StudioViewModel {
    /// The learner's chats as Home's sidebar lists them: the pinned ones in
    /// their order, then the rest in the rail's order (newest first, as
    /// arranged). A day's memory review, a hidden chat and a shared link are
    /// not listed there and are left out.
    func chatsInSidebarOrder() -> [ReviewSessionRecord] {
        let listed = filteredReviewSessionLinks().filter {
            !$0.isExternalLink && !MemoryReviewSession.isMemorySession($0.id)
        }
        let byID = Dictionary(listed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pinned = chatPins.orderedSessionIDs.compactMap { byID[$0] }
        let pinnedIDs = Set(pinned.map(\.id))
        return pinned + listed.filter { !pinnedIDs.contains($0.id) }
    }

    /// The chats started most recently, newest first: Codex's recent chats.
    func recentChats() -> [ReviewSessionRecord] {
        chatsInSidebarOrder().sorted { $0.createdAt > $1.createdAt }
    }
}

// MARK: - The host: one per Studio window

/// Hosts the command menu, the Keyboard shortcuts sheet and the Rename Chat
/// prompt over a Studio window, and runs every `ShellAction` the menu bar or
/// the command menu asks this window for.
struct ShellCommandHost: ViewModifier {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    @Environment(\.openWindow) private var openWindow
    @SyncedStorage("uiZoomStep") private var uiZoomStep = UIZoom.defaultStep
    /// Reopens the chat and the source a place in the window's history showed.
    let reopen: (StudioWindowPlace) -> Void

    @State private var showsCommandMenu = false
    @State private var showsShortcuts = false
    @State private var renamingChatID: String?
    @State private var renameText = ""

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if showsCommandMenu {
                    ZStack(alignment: .top) {
                        // A click beside the panel closes it, as Codex's.
                        Color.black.opacity(0.001)
                            .contentShape(Rectangle())
                            .onTapGesture { showsCommandMenu = false }
                        CommandMenuPanel(
                            dismiss: { showsCommandMenu = false },
                            perform: { command in
                                showsCommandMenu = false
                                run(command)
                            }
                        )
                        .padding(.top, 64)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: showsCommandMenu)
            .background { aliasKeys }
            .sheet(isPresented: $showsShortcuts) {
                KeyboardShortcutsSheet { showsShortcuts = false }
            }
            .alert("Rename Chat", isPresented: Binding(
                get: { renamingChatID != nil },
                set: { if !$0 { renamingChatID = nil } }
            )) {
                TextField("Title", text: $renameText)
                Button("Cancel", role: .cancel) { renamingChatID = nil }
                Button("Rename") {
                    let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let id = renamingChatID, !title.isEmpty {
                        Task { await vm.renameReviewSession(id, title: title) }
                    }
                    renamingChatID = nil
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .shellAction)) { note in
                guard handles(note),
                      let raw = note.userInfo?[ShellActionRequest.actionKey] as? String,
                      let action = ShellAction(rawValue: raw) else { return }
                perform(action)
            }
            .onReceive(NotificationCenter.default.publisher(for: .shellGoToChat)) { note in
                guard handles(note), let index = note.userInfo?[ShellActionRequest.chatIndexKey] as? Int else { return }
                let recent = note.userInfo?[ShellActionRequest.recentKey] as? Bool ?? false
                let chats = recent ? vm.recentChats() : vm.chatsInSidebarOrder()
                guard chats.indices.contains(index) else { return }
                openChat(chats[index].id)
            }
    }

    private func handles(_ note: Notification) -> Bool {
        if let id = note.object as? UUID { return id == windowState.id }
        return StudioWindowRegistry.shared.activeState === windowState
    }

    /// Codex's second keys for a command (⇧⌘S beside ⌃⌘S, ⌃Tab beside
    /// ⇧⌘]): a menu item carries one key, so the window binds the others.
    private var aliasKeys: some View {
        ZStack {
            ForEach(ShellAction.allCases.filter { !$0.aliasKeys.isEmpty }, id: \.self) { action in
                ForEach(action.aliasKeys, id: \.self) { key in
                    Button(action.title) { perform(action) }
                        .keyboardShortcut(key.keyboardShortcut)
                }
            }
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Running a row

    private func run(_ command: ShellCommand) {
        switch command.target {
        case .action(let action):
            perform(action)
        case .place(let tab):
            openPlace(tab)
        case .spacePlace(let place):
            vm.inWindow(windowState) { vm.showSpace(place, in: windowState) }
        case .chat(let id):
            openChat(id)
        case .notebook(let id):
            StudioWindowDestination.notebook(id).open(in: windowState, vm: vm)
        case .page(let id):
            StudioWindowDestination.doc(id).open(in: windowState, vm: vm)
        case .source(let id):
            vm.activateCenterTab(.reader, in: windowState)
            Task { await vm.selectArticle(id, in: windowState) }
        case .settings(let pane):
            NotificationCenter.default.post(name: .requestOpenStudioSettings, object: pane)
        }
    }

    private func openPlace(_ tab: StudioCenterTab) {
        let destination: StudioWindowDestination?
        switch tab {
        case .artifacts: destination = .artifacts
        case .notepad: destination = .docs
        case .sites: destination = .sites
        case .courses: destination = .courses
        case .goals: destination = .goals
        case .ideas: destination = .ideas
        case .memory: destination = .memory
        case .library: destination = .library
        case .plugins: destination = .plugins(.directory)
        case .activity: destination = .activity
        case .activityLog: destination = .activityLog
        case .browser: destination = .browser
        case .knowledgeMap: destination = .knowledgeMap
        case .atlas: destination = .atlas
        case .reader:
            destination = nil
            NotificationCenter.default.post(name: .openStudioReader, object: windowState.id)
        case .videos:
            destination = nil
            vm.inWindow(windowState) { vm.openVideosInReader() }
        case .animations:
            destination = nil
            vm.inWindow(windowState) { vm.activateCenterTab(.animations, in: windowState) }
        case .chat, .secondaryChat, .secondaryReader, .secondaryBrowser, .tasks:
            destination = nil
        case .liveMeeting:
            destination = nil
            vm.openLiveMeeting(in: windowState)
        }
        destination?.open(in: windowState, vm: vm)
    }

    private func openChat(_ id: String) {
        vm.inWindow(windowState) { vm.requestResumeReviewSession(id) }
    }

    // MARK: Running a command

    private var shownChatID: String? {
        guard let id = windowState.chatSessionID, !MemoryReviewSession.isMemorySession(id) else { return nil }
        return id
    }

    private func perform(_ action: ShellAction) {
        switch action {
        case .commandMenu:
            showsCommandMenu.toggle()
        case .keyboardShortcuts:
            showsShortcuts = true
        case .settings:
            NotificationCenter.default.post(name: .requestOpenStudioSettings, object: nil)
        case .toggleSidebar:
            withAnimation(.easeInOut(duration: 0.22)) {
                // As the View menu's item and the sidebar toggle: Home's
                // sidebar and the Space's fold together, never the strip,
                // and a place with no sidebar gets Home's beside it.
                let defaults = UserDefaults.standard
                let shown = !windowState.sidebarToggleReadsShown(spaceSidebarHidden: defaults.bool(forKey: "space.sidebarHidden"))
                if let spaceHidden = windowState.setSidebarShownFromToggle(shown) {
                    defaults.set(spaceHidden, forKey: "space.sidebarHidden")
                }
            }
        case .back:
            guard windowState.canGoBackInPlaces else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                if let place = windowState.goBackInPlaces() { reopen(place) }
            }
        case .forward:
            guard windowState.canGoForwardInPlaces else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                if let place = windowState.goForwardInPlaces() { reopen(place) }
            }
        case .newWindow:
            openWindow(id: "studio")
        case .zoomIn:
            uiZoomStep = min(uiZoomStep + 1, UIZoom.maxStep)
        case .zoomOut:
            uiZoomStep = max(uiZoomStep - 1, UIZoom.minStep)
        case .resetZoom:
            uiZoomStep = UIZoom.defaultStep
            ChatZoomShortcutRouter.shared.resetAll(in: NSApp.keyWindow)
        case .whatsNew:
            NotificationCenter.default.post(name: .showWhatsNew, object: windowState.id)
        case .newChat:
            vm.inWindow(windowState) { vm.requestNewChat() }
        case .sideChat:
            // Codex's side chat: the popover about the whole conversation
            // (`/side`), opened by the window's docked chat.
            NotificationCenter.default.post(name: .openThreadSideChat, object: windowState.id)
        case .quickChat:
            QuickAssistantController.shared.shortcutPressed()
        case .openChat:
            NotificationCenter.default.post(name: .toggleStudioAssistant, object: windowState.id)
        case .previousChat, .nextChat:
            let chats = vm.chatsInSidebarOrder().map(\.id)
            guard !chats.isEmpty else { return }
            let step = action == .nextChat ? 1 : -1
            let next: String
            if let current = shownChatID, let index = chats.firstIndex(of: current) {
                next = chats[(index + step + chats.count) % chats.count]
            } else {
                next = step > 0 ? chats[0] : chats[chats.count - 1]
            }
            openChat(next)
        case .nextUnreadChat:
            let unread = ChatReadMarks.shared.unreadSessionIDs
            let chats = vm.chatsInSidebarOrder().map(\.id).filter(unread.contains)
            guard !chats.isEmpty else {
                vm.showToast("No unread chats")
                return
            }
            let after = shownChatID.flatMap { current in chats.first { $0 != current } } ?? chats[0]
            openChat(after)
        case .renameChat:
            guard let id = shownChatID else { return }
            renameText = vm.reviewSessionLinks.first { $0.id == id }?.title ?? ""
            renamingChatID = id
        case .togglePinChat:
            guard let id = shownChatID else { return }
            let pinned = !vm.isChatPinned(id)
            vm.setChatPinned(id, pinned: pinned)
            vm.showToast(pinned ? "Chat pinned" : "Chat unpinned")
        case .markChatUnread:
            guard let id = shownChatID else { return }
            ChatReadMarks.shared.markUnread(id)
        case .hideChat:
            guard let id = shownChatID else { return }
            Task { await vm.setReviewSessionHidden(id, hidden: true) }
            vm.showToast("Chat hidden")
        case .copyChatLink:
            guard let id = shownChatID else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(StudioEntityLink.chat(id).markdownDestination, forType: .string)
            vm.showToast("Link copied")
        case .copyConversation:
            guard let id = shownChatID else { return }
            Task { await vm.copyChatConversation(id) }
        case .clearUnread:
            ChatReadMarks.shared.markAllRead()
        case .selectModel:
            NotificationCenter.default.post(name: .openChatModelPicker, object: UUID())
        case .newPage:
            let window = windowState
            Task {
                do {
                    let snapshot = try await vm.createArtifact(
                        title: ArtifactPlaceholderTitle.current,
                        homeNotebookID: nil,
                        linkedNotebookIDs: [],
                        pageSpaceID: nil
                    )
                    vm.revealArtifact(snapshot.artifact.id, in: window)
                } catch {
                    vm.errorMessage = error.localizedDescription
                }
            }
        case .openReader:
            NotificationCenter.default.post(name: .openStudioReader, object: windowState.id)
        case .space:
            NotificationCenter.default.post(name: .openStudioSpace, object: windowState.id)
        case .library:
            NotificationCenter.default.post(name: .openStudioLibrary, object: windowState.id)
        case .addSources:
            NotificationCenter.default.post(name: .showNotebookAddSources, object: windowState.id)
        case .dailyNotes:
            let window = windowState
            Task { await vm.openDailyNote(in: window) }
        case .planTheDay:
            NotificationCenter.default.post(name: .requestPlanTheDayChat, object: windowState.id)
        case .todaysReview:
            vm.inWindow(windowState) { vm.requestCardReview(scope: .allNotebooks) }
        case .startPomodoro:
            if DayModel.shared.liveBout == nil {
                DayModel.shared.requestStart()
            } else {
                DayModel.shared.requestWriteUp()
            }
        }
    }
}

extension View {
    /// The command menu, the ⌘/ sheet and the shell's commands, over a
    /// Studio window.
    func shellCommandHost(reopen: @escaping (StudioWindowPlace) -> Void) -> some View {
        modifier(ShellCommandHost(reopen: reopen))
    }
}

// MARK: - The panel

/// Codex's command menu: one field, "Search chats or run a command", and the
/// rows grouped under it — Quick actions, Pinned and Recent chats and Recent
/// Pages before anything is typed; commands, places, chats, notebooks, Pages,
/// sources and settings as the learner types. ↑ ↓ move, Return runs, Escape
/// or a click beside it closes.
struct CommandMenuPanel: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    @SyncedStorage(wrappedValue: false, BetaReleases.preferenceKey) private var signedUpForBetas: Bool
    let dismiss: () -> Void
    let perform: (ShellCommand) -> Void

    @State private var query = ""
    @State private var selectedID: String?
    /// The sources the library's index found for `sourceHitsQuery`.
    @State private var sourceHits: [ShellCommand] = []
    @State private var sourceHitsQuery = ""
    @State private var isSearchingSources = false
    @State private var keyMonitor: Any?
    @FocusState private var fieldFocused: Bool

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        let sections = currentSections
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search chats or run a command", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($fieldFocused)
                    .accessibilityIdentifier("commandMenu.field")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            Divider()
            if sections.isEmpty {
                Text(isSearchingSources ? "Searching…" : "No matches")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(sections, id: \.group) { section in
                                Text(section.group.title)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 14)
                                    .padding(.top, 10)
                                    .padding(.bottom, 4)
                                ForEach(section.commands) { command in
                                    CommandMenuRow(command: command, isSelected: command.id == selectedID)
                                        .id(command.id)
                                        .onTapGesture { perform(command) }
                                        .onHover { if $0 { selectedID = command.id } }
                                }
                            }
                        }
                        .padding(.bottom, 6)
                    }
                    .frame(maxHeight: 420)
                    .onChange(of: selectedID) { _, id in
                        guard let id else { return }
                        proxy.scrollTo(id)
                    }
                }
            }
        }
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command menu")
        .onAppear {
            fieldFocused = true
            selectedID = currentSections.first?.commands.first?.id
            installKeyMonitor()
        }
        .onDisappear(perform: removeKeyMonitor)
        .onChange(of: query) { _, _ in
            selectedID = currentSections.first?.commands.first?.id
        }
        .task(id: trimmedQuery) { await searchSources(trimmedQuery) }
    }

    // MARK: Rows

    private var currentSections: [ShellCommandSection] {
        let query = trimmedQuery
        let chats = chatCommands
        guard !query.isEmpty else {
            return ShellCommands.emptyQuerySections(chats: chats, pages: pageCommands)
        }
        let showsChat = windowState.chatSessionID.map { !MemoryReviewSession.isMemorySession($0) } ?? false
        var commands = ShellCommands.actions(showsChat: showsChat, inNotebook: windowState.notebook != nil)
        commands += ShellCommands.places(includingBeta: BetaFeatures.showsCanvas(signedUpForBetas: signedUpForBetas))
        commands += chats
        commands += notebookCommands
        commands += pageCommands
        commands += sourceCommands(matching: query)
        commands += SettingsSearchCatalog.items().map {
            ShellCommands.setting(title: $0.title, subtitle: $0.subtitle, keywords: $0.keywords, pane: $0.destination)
        }
        return ShellCommands.sections(for: commands, query: query)
    }

    private var chatCommands: [ShellCommand] {
        let notebookTitles = Dictionary(vm.notebooks.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        return vm.chatsInSidebarOrder().map { record in
            ShellCommands.chat(
                id: record.id,
                title: record.title,
                subtitle: record.goalID.flatMap { notebookTitles[$0] } ?? "",
                isPinned: vm.isChatPinned(record.id)
            )
        }
    }

    private var notebookCommands: [ShellCommand] {
        vm.notebooks.sorted { $0.updatedAt > $1.updatedAt }.map { notebook in
            let count = notebook.approvedSourceIDs.count
            return ShellCommands.notebook(id: notebook.id, title: notebook.title, subtitle: count == 1 ? "1 source" : "\(count) sources")
        }
    }

    /// Pages and Sites, newest first, as the Space lists them.
    private var pageCommands: [ShellCommand] {
        vm.artifacts
            .filter {
                !TeamContentIdentity.isDraftArtifactID($0.id) && !$0.isArchived && !$0.isHidden
                    && !vm.isAudioOverview($0)
                    && [.docs, .sites].contains(vm.section(of: $0))
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { artifact in
                ShellCommands.page(id: artifact.id, title: artifact.title, subtitle: vm.section(of: artifact) == .sites ? "Site" : "")
            }
    }

    /// Sources whose title matches at once, then what the library's index
    /// (`SourceSearchEngine`) found in their text, for this query.
    private func sourceCommands(matching query: String) -> [ShellCommand] {
        let titled = searchableSources.filter { article in
            ShellCommands.matchTier(sourceCommand(article, matchedByIndex: false), query: query).map { $0 <= 3 } ?? false
        }
        .prefix(ShellCommandGroup.sources.searchLimit)
        .map { sourceCommand($0, matchedByIndex: false) }
        let titledIDs = Set(titled.map(\.id))
        let indexed = sourceHitsQuery == query ? sourceHits.filter { !titledIDs.contains($0.id) } : []
        return titled + indexed
    }

    private var searchableSources: [StudioArticle] {
        vm.articles.filter { vm.isSourceIncludedInKnowledge($0) && !vm.isSourceHidden($0) }
    }

    private func sourceCommand(_ article: StudioArticle, matchedByIndex: Bool) -> ShellCommand {
        let author = article.author?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ShellCommands.source(
            id: article.id,
            title: article.title,
            subtitle: author.isEmpty ? article.domain : author,
            matchedByIndex: matchedByIndex
        )
    }

    private func searchSources(_ query: String) async {
        guard query.count >= 2 else {
            sourceHits = []
            sourceHitsQuery = query
            return
        }
        // Typing settles before the index is asked.
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled else { return }
        isSearchingSources = true
        defer { isSearchingSources = false }
        let hits = await vm.storage.searchSources(queryText: query, queryVector: nil, limit: 12)
        guard !Task.isCancelled else { return }
        let byID = Dictionary(searchableSources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        sourceHits = hits.compactMap { hit in byID[hit.sourceId].map { sourceCommand($0, matchedByIndex: true) } }
        sourceHitsQuery = query
    }

    // MARK: Keys

    /// ↑ ↓ Return and Escape while the panel is up, read before the field
    /// takes them, in this window only.
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard StudioWindowRegistry.shared.activeState === windowState else { return event }
            switch event.keyCode {
            case 125: // ↓
                selectedID = ShellCommands.row(after: selectedID, step: 1, in: currentSections)
                return nil
            case 126: // ↑
                selectedID = ShellCommands.row(after: selectedID, step: -1, in: currentSections)
                return nil
            case 36, 76: // Return, Enter
                let rows = currentSections.flatMap(\.commands)
                if let command = rows.first(where: { $0.id == selectedID }) ?? rows.first {
                    perform(command)
                }
                return nil
            case 53: // Escape
                dismiss()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

private struct CommandMenuRow: View {
    let command: ShellCommand
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: command.glyph)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(command.title)
                .font(.system(size: 13))
                .lineLimit(1)
            if !command.subtitle.isEmpty {
                Text(command.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let key = command.keys.first {
                Text(key.display)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.07) : .clear)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - The ⌘/ sheet

/// Codex's Keyboard shortcuts dialog, read-only: the app's keys by section,
/// with a search over their names and keys.
struct KeyboardShortcutsSheet: View {
    let done: () -> Void
    @State private var search = ""

    var body: some View {
        let sections = filteredSections
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard shortcuts")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            TextField("Search shortcuts", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if sections.isEmpty {
                        Text("No matching shortcuts")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 20)
                    }
                    ForEach(sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(section.title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            ForEach(section.entries, id: \.self) { entry in
                                HStack {
                                    Text(entry.title)
                                    Spacer()
                                    Text(entry.keysDisplay)
                                        .foregroundStyle(.secondary)
                                }
                                .font(.system(size: 13))
                                .padding(.vertical, 3)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 460, height: 560)
    }

    private var filteredSections: [(title: String, entries: [ShellShortcutEntry])] {
        let wanted = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return ShellKeyboardShortcuts.sections }
        return ShellKeyboardShortcuts.sections.compactMap { section in
            let entries = section.entries.filter {
                $0.title.localizedStandardContains(wanted) || $0.keysDisplay.localizedStandardContains(wanted)
            }
            return entries.isEmpty ? nil : (section.title, entries)
        }
    }
}


extension StudioViewModel {
    /// The whole chat as text on the pasteboard, read from what is saved, so it
    /// works for a chat no panel has open (a sidebar row, the menu bar). The
    /// chat's own ⋯ copies from the panel, which also holds a reply in flight.
    @MainActor
    func copyChatConversation(_ sessionID: String) async {
        do {
            let exchanges = try await storage.loadReviewSessionExchanges(sessionID: sessionID)
            let transcript = ReviewSessionManager.copiedConversationText(fromStored: exchanges)
            guard !transcript.isEmpty else {
                showToast("Nothing to copy yet")
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(transcript, forType: .string)
            showToast("Conversation copied")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
