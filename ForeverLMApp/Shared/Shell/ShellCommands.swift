import Foundation

// MARK: - The command menu and the key table
//
// Codex's command menu: one field, "Search chats or run a command", that finds
// chats, Pages, settings and every app command, opened with ⇧⌘P or ⌘K, and
// its read-only Keyboard shortcuts sheet on ⌘/ (codex.commandMenu.*,
// keyboardShortcutsDialog.*; learn.chatgpt.com/docs/reference/commands).
// ForeverLM copies it first and adds what it has on top: its places, its
// notebooks and its sources (product owner, 2026-10-13: "at first it should be
// a copy of the codex ... functionality; THEN we can gradually add some
// features on top"; docs/codex-parity-audit.md, section 6 and lane E).
//
// View-free: the rows, their groups, the ranking and the key table. The panel
// (`App/CommandMenu.swift`) gathers the learner's chats, notebooks, Pages and
// sources into rows with the builders below and runs what is chosen; the menu
// bar binds its keys from the same table, so the ⌘/ sheet cannot drift from
// what the keys do.

// MARK: - Keys

/// The modifier keys of a shortcut, in the order macOS writes them: ⌃⌥⇧⌘.
struct ShellKeyModifiers: OptionSet, Hashable, Sendable {
    let rawValue: Int

    static let control = ShellKeyModifiers(rawValue: 1 << 0)
    static let option = ShellKeyModifiers(rawValue: 1 << 1)
    static let shift = ShellKeyModifiers(rawValue: 1 << 2)
    static let command = ShellKeyModifiers(rawValue: 1 << 3)
}

/// One keystroke: a character key ("k", "[", "/", "1") or a named one
/// (`tab`, `escape`, `return`), with its modifiers.
struct ShellKey: Hashable, Sendable {
    static let tab = "tab"
    static let escape = "escape"
    static let returnKey = "return"

    let key: String
    let modifiers: ShellKeyModifiers

    init(_ key: String, _ modifiers: ShellKeyModifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    static func command(_ key: String) -> ShellKey { ShellKey(key, .command) }

    /// As the menu bar writes it: ⇧⌘P, ⌃Tab, ⇧Esc.
    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case Self.tab: text += "Tab"
        case Self.escape: text += "Esc"
        case Self.returnKey: text += "↩"
        default: text += key.uppercased()
        }
        return text
    }
}

// MARK: - App commands

/// Every command the menu bar and the command menu share. Its keys are the
/// table both read: the first is the menu bar's own, the rest are aliases the
/// window binds beside it (Codex gives several commands two keys).
enum ShellAction: String, CaseIterable, Sendable {
    // General
    case commandMenu
    case keyboardShortcuts
    case settings
    case toggleSidebar
    case back
    case forward
    case newWindow
    case zoomIn
    case zoomOut
    case resetZoom
    case whatsNew

    // Chats
    case newChat
    case sideChat
    case quickChat
    case openChat
    case previousChat
    case nextChat
    case nextUnreadChat
    case renameChat
    case togglePinChat
    case markChatUnread
    case hideChat
    case copyChatLink
    case copyConversation
    case clearUnread
    case selectModel

    // ForeverLM's own
    case newPage
    case openReader
    case space
    case library
    case addSources
    case dailyNotes
    case planTheDay
    case todaysReview
    case startPomodoro

    var title: String {
        switch self {
        case .commandMenu: return "Command Menu"
        case .keyboardShortcuts: return "Keyboard Shortcuts"
        case .settings: return "Settings…"
        case .toggleSidebar: return "Toggle Sidebar"
        case .back: return "Back"
        case .forward: return "Forward"
        case .newWindow: return "New Window"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .resetZoom: return "Reset Zoom"
        case .whatsNew: return "What's New in ForeverLM"
        case .newChat: return "New Chat"
        case .sideChat: return "Side Chat"
        case .quickChat: return "Quick Chat"
        case .openChat: return "Open Chat"
        case .previousChat: return "Previous Chat"
        case .nextChat: return "Next Chat"
        case .nextUnreadChat: return "Next Unread Chat"
        case .renameChat: return "Rename Chat…"
        case .togglePinChat: return "Pin or Unpin Chat"
        case .markChatUnread: return "Mark Chat as Unread"
        case .hideChat: return "Hide Chat"
        case .copyChatLink: return "Copy Chat Link"
        case .copyConversation: return "Copy Conversation"
        case .clearUnread: return "Mark All Chats as Read"
        case .selectModel: return "Select Model"
        case .newPage: return "New Page"
        case .openReader: return "Open Reader"
        case .space: return "Space"
        case .library: return "Library"
        case .addSources: return "Add Sources…"
        case .dailyNotes: return "Daily Notes"
        case .planTheDay: return "Plan the Day in Chat"
        case .todaysReview: return "Today's Review"
        case .startPomodoro: return "Start Pomodoro Timer…"
        }
    }

    /// An SF Symbol for the command menu's row.
    var glyph: String {
        switch self {
        case .commandMenu: return "command"
        case .keyboardShortcuts: return "keyboard"
        case .settings: return "gearshape"
        case .toggleSidebar: return "sidebar.left"
        case .back: return "arrow.left"
        case .forward: return "arrow.right"
        case .newWindow: return "macwindow.badge.plus"
        case .zoomIn: return "plus.magnifyingglass"
        case .zoomOut: return "minus.magnifyingglass"
        case .resetZoom: return "1.magnifyingglass"
        case .whatsNew: return "sparkles"
        case .newChat: return "square.and.pencil"
        case .sideChat: return "bubble.left.and.text.bubble.right"
        case .quickChat: return "bolt.horizontal.circle"
        case .openChat: return "bubble.left"
        case .previousChat: return "chevron.up"
        case .nextChat: return "chevron.down"
        case .nextUnreadChat: return "circle.fill"
        case .renameChat: return "pencil"
        case .togglePinChat: return "pin"
        case .markChatUnread: return "circle.badge"
        case .hideChat: return "eye.slash"
        case .copyChatLink: return "link"
        case .copyConversation: return "doc.on.doc"
        case .clearUnread: return "checkmark.circle"
        case .selectModel: return "cpu"
        case .newPage: return "doc.badge.plus"
        case .openReader: return "doc.text"
        case .space: return "square.on.square"
        case .library: return "books.vertical"
        case .addSources: return "plus.rectangle.on.folder"
        case .dailyNotes: return "calendar.day.timeline.left"
        case .planTheDay: return "calendar"
        case .todaysReview: return "brain"
        case .startPomodoro: return "timer"
        }
    }

    /// Other words a learner may type for it.
    var keywords: [String] {
        switch self {
        case .commandMenu: return ["search", "run", "command palette"]
        case .keyboardShortcuts: return ["keys", "hotkeys", "keybindings", "help"]
        case .settings: return ["preferences", "options"]
        case .toggleSidebar: return ["hide sidebar", "show sidebar", "navigation"]
        case .back: return ["previous place", "go back"]
        case .forward: return ["next place", "go forward"]
        case .newWindow: return ["window"]
        case .zoomIn: return ["bigger", "larger", "font size", "text size"]
        case .zoomOut: return ["smaller", "font size", "text size"]
        case .resetZoom: return ["actual size", "font size"]
        case .whatsNew: return ["changelog", "release notes", "updates"]
        case .newChat: return ["start chat", "conversation", "ask"]
        case .sideChat: return ["side question", "about this conversation", "aside"]
        case .quickChat: return ["quick assistant", "floating"]
        case .openChat: return ["ask about selection", "explain", "composer", "assistant"]
        case .previousChat: return ["chat above", "switch chat"]
        case .nextChat: return ["chat below", "switch chat"]
        case .nextUnreadChat: return ["attention", "unread", "finished reply"]
        case .renameChat: return ["title"]
        case .togglePinChat: return ["pin chat", "unpin chat", "keep"]
        case .markChatUnread: return ["unread", "dot"]
        case .hideChat: return ["archive chat", "put away"]
        case .copyChatLink: return ["deep link", "address", "url", "share"]
        case .copyConversation: return ["copy chat", "whole chat", "transcript", "copy all", "clipboard"]
        case .clearUnread: return ["read", "clear unread", "dots"]
        case .selectModel: return ["model picker", "recent models", "llm"]
        case .newPage: return ["new doc", "write", "note", "document"]
        case .openReader: return ["read", "source"]
        case .space: return ["home", "everything", "all"]
        case .library: return ["sources", "manage library"]
        case .addSources: return ["import", "upload", "notebook sources"]
        case .dailyNotes: return ["journal", "today's page", "diary"]
        case .planTheDay: return ["plan", "calendar", "schedule"]
        case .todaysReview: return ["memory", "cards", "flashcards", "review"]
        case .startPomodoro: return ["timer", "bout", "focus"]
        }
    }

    /// The keys, the menu bar's first. Empty for a command with no key.
    var keys: [ShellKey] {
        switch self {
        // Codex's two keys. ⌘K was Open Chat until 2026-10-13 (now ⇧⌘K).
        case .commandMenu: return [.command("k"), ShellKey("p", [.command, .shift])]
        case .keyboardShortcuts: return [.command("/")]
        case .settings: return [.command(",")]
        // ForeverLM's ⌃⌘S (macOS's sidebar key) and Codex's ⇧⌘S; Codex's ⌘B
        // stays Bold inside a page.
        case .toggleSidebar: return [ShellKey("s", [.command, .control]), ShellKey("s", [.command, .shift])]
        case .back: return [.command("[")]
        case .forward: return [.command("]")]
        // ⌘N is Codex's New Chat; a window is ⌃⌘N.
        case .newWindow: return [ShellKey("n", [.command, .control])]
        case .zoomIn: return [.command("+")]
        case .zoomOut: return [.command("-")]
        case .resetZoom: return [.command("0")]
        case .whatsNew: return []
        case .newChat: return [.command("n"), ShellKey("o", [.command, .shift])]
        case .sideChat: return [ShellKey("s", [.command, .option])]
        case .quickChat: return [ShellKey("n", [.command, .option])]
        case .openChat: return [ShellKey("k", [.command, .shift])]
        case .previousChat: return [ShellKey("[", [.command, .shift]), ShellKey(ShellKey.tab, [.control, .shift])]
        case .nextChat: return [ShellKey("]", [.command, .shift]), ShellKey(ShellKey.tab, .control)]
        case .nextUnreadChat: return [ShellKey("a", [.command, .option])]
        case .renameChat: return [ShellKey("r", [.command, .option])]
        case .togglePinChat: return [ShellKey("p", [.command, .option])]
        case .markChatUnread: return [ShellKey("u", [.command, .shift])]
        // Codex's Archive chat; Hide is ForeverLM's put-away.
        case .hideChat: return [ShellKey("a", [.command, .shift])]
        case .copyChatLink: return [ShellKey("l", [.command, .option])]
        // The whole chat as text, from anywhere in the window (product owner,
        // 2026-10-15: "make sure in foreverlm i can always copy the whole chat").
        case .copyConversation: return [ShellKey("c", [.command, .shift])]
        case .clearUnread: return [ShellKey(ShellKey.escape, .shift)]
        // Codex's model picker and its Open recent models; ForeverLM's picker
        // leads with the recent models, so both open it.
        case .selectModel: return [ShellKey("m", [.control, .shift]), ShellKey("m", [.command, .control])]
        // Shown, not bound by the menu bar: the Space binds it while it shows.
        case .newPage: return [ShellKey("n", [.command, .shift])]
        case .openReader: return [.command("r")]
        case .space: return [.command("p")]
        case .library: return [ShellKey("l", [.command, .shift])]
        // ⇧⌘A is Codex's Archive (Hide Chat); Add Sources… is ⇧⌘I, "import".
        case .addSources: return [ShellKey("i", [.command, .shift])]
        case .dailyNotes: return [ShellKey("d", [.command, .shift])]
        case .planTheDay: return [.command("d")]
        case .todaysReview: return []
        case .startPomodoro: return [ShellKey("b", [.command, .shift])]
        }
    }

    /// The menu bar's key.
    var key: ShellKey? { keys.first }

    /// The keys the window binds beside the menu bar's.
    var aliasKeys: [ShellKey] { Array(keys.dropFirst()) }

    /// Commands that act on the chat the window shows: offered by the
    /// command menu only while it shows one.
    var needsChat: Bool {
        switch self {
        case .renameChat, .togglePinChat, .markChatUnread, .hideChat, .copyChatLink, .copyConversation: return true
        default: return false
        }
    }

    /// The commands the command menu lists: every one but itself.
    static var listed: [ShellAction] {
        allCases.filter { $0 != .commandMenu }
    }

    /// Codex's Quick actions: what the menu offers before anything is typed.
    static let quickActions: [ShellAction] = [.newChat, .newPage, .planTheDay, .todaysReview, .keyboardShortcuts]
}

// MARK: - Rows

/// What a row opens or runs.
enum ShellCommandTarget: Hashable, Sendable {
    case action(ShellAction)
    /// A place of the window, by its pane (`ShellPlaces`).
    case place(StudioCenterTab)
    /// One of the Space sidebar's places.
    case spacePlace(SpaceDestination)
    case chat(String)
    case notebook(String)
    case page(String)
    case source(String)
    case settings(SettingsPane)
}

/// The groups the menu draws, in the order they show when they match
/// equally well. Codex's: Quick actions, Pinned chats, Recent chats, Chats,
/// Recent Pages, Pages, Settings; ForeverLM adds places, notebooks and
/// sources.
enum ShellCommandGroup: Int, CaseIterable, Sendable {
    case quickActions
    case pinnedChats
    case recentChats
    case commands
    case places
    case chats
    case notebooks
    case recentPages
    case pages
    case sources
    case settings

    var title: String {
        switch self {
        case .quickActions: return "Quick actions"
        case .pinnedChats: return "Pinned chats"
        case .recentChats: return "Recent chats"
        case .commands: return "Commands"
        case .places: return "Places"
        case .chats: return "Chats"
        case .notebooks: return "Notebooks"
        case .recentPages: return "Recent Pages"
        case .pages: return "Pages"
        case .sources: return "Sources"
        case .settings: return "Settings"
        }
    }

    /// How many rows a search shows of it.
    var searchLimit: Int {
        switch self {
        case .commands, .chats, .sources: return 6
        case .pages: return 5
        case .places, .notebooks: return 4
        case .settings: return 3
        case .quickActions, .pinnedChats, .recentChats, .recentPages: return 5
        }
    }
}

/// One row of the command menu.
struct ShellCommand: Identifiable, Hashable, Sendable {
    let target: ShellCommandTarget
    let title: String
    /// The grey line beside the title: a chat's notebook, a source's author.
    let subtitle: String
    let keywords: [String]
    let glyph: String
    /// The keys shown at the row's end.
    let keys: [ShellKey]
    /// A chat the learner pinned.
    let isPinned: Bool
    /// A source the library's index matched by its text, not its title.
    let matchedByIndex: Bool

    init(
        target: ShellCommandTarget,
        title: String,
        subtitle: String = "",
        keywords: [String] = [],
        glyph: String,
        keys: [ShellKey] = [],
        isPinned: Bool = false,
        matchedByIndex: Bool = false
    ) {
        self.target = target
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.glyph = glyph
        self.keys = keys
        self.isPinned = isPinned
        self.matchedByIndex = matchedByIndex
    }

    var id: String {
        switch target {
        case .action(let action): return "action.\(action.rawValue)"
        case .place(let tab): return "place.\(tab.rawValue)"
        case .spacePlace(let place): return "space.\(place.key)"
        case .chat(let id): return "chat.\(id)"
        case .notebook(let id): return "notebook.\(id)"
        case .page(let id): return "page.\(id)"
        case .source(let id): return "source.\(id)"
        case .settings(let pane): return "settings.\(pane)"
        }
    }

    /// The group a search files it under.
    var searchGroup: ShellCommandGroup {
        switch target {
        case .action: return .commands
        case .place, .spacePlace: return .places
        case .chat: return .chats
        case .notebook: return .notebooks
        case .page: return .pages
        case .source: return .sources
        case .settings: return .settings
        }
    }
}

/// One group of rows as the menu draws it.
struct ShellCommandSection: Equatable, Sendable {
    let group: ShellCommandGroup
    let commands: [ShellCommand]
}

// MARK: - Building rows

enum ShellCommands {
    /// Codex's word for a chat with no title.
    static let untitledChat = "Untitled chat"
    static let untitledPage = "Untitled"

    /// The panes the menu offers as places, in the strip's spirit: the
    /// Space and what it lists, then the module places. The chat panes are
    /// New Chat's, and Tasks has no way in (product owner, 2026-10-13:
    /// "scheduled is not so important btw; skip that for now").
    static let placeTabs: [StudioCenterTab] = [
        .artifacts, .notepad, .sites, .courses, .goals, .ideas,
        .memory, .library, .plugins, .reader, .activity, .activityLog, .browser, .videos, .animations,
        .knowledgeMap, .atlas,
    ]

    /// The Space sidebar's places the menu offers beside the panes.
    static let spacePlaces: [SpaceDestination] = [.notebooks, .images]

    /// Beta places (`BetaFeatures`): offered only where the Canvas shows.
    static let betaPlaceTabs: Set<StudioCenterTab> = [.knowledgeMap, .atlas]

    static func placeKeywords(_ tab: StudioCenterTab) -> [String] {
        switch tab {
        case .artifacts: return ["everything", "all"]
        case .notepad: return ["docs", "documents", "notes", "writing"]
        case .sites: return ["artifacts", "web pages", "published"]
        case .courses: return ["lectures", "quizzes", "class"]
        case .goals: return ["targets", "deadlines"]
        case .ideas: return ["thoughts", "jots"]
        case .memory: return ["cards", "flashcards", "review", "to check"]
        case .library: return ["sources", "papers", "books", "articles", "podcasts"]
        case .plugins: return ["connectors", "integrations", "skills"]
        case .reader: return ["read", "source"]
        case .activity: return ["day", "today", "calendar", "meetings"]
        case .activityLog: return ["activity", "log", "history", "time spent", "tracked"]
        case .browser: return ["web", "tabs", "internet"]
        case .videos: return ["films", "explainers"]
        case .animations: return ["moving explanations"]
        case .knowledgeMap: return ["canvas", "map", "board"]
        case .atlas: return ["concepts", "levels"]
        default: return []
        }
    }

    static func actions(showsChat: Bool, inNotebook: Bool) -> [ShellCommand] {
        ShellAction.listed
            .filter { showsChat || !$0.needsChat }
            .filter { inNotebook || $0 != .addSources }
            .map(command(for:))
    }

    static func command(for action: ShellAction) -> ShellCommand {
        ShellCommand(
            target: .action(action),
            title: action.title,
            keywords: action.keywords,
            glyph: action.glyph,
            keys: action.keys
        )
    }

    static func places(includingBeta: Bool) -> [ShellCommand] {
        let panes = placeTabs
            .filter { includingBeta || !betaPlaceTabs.contains($0) }
            .map { tab -> ShellCommand in
                let place = ShellPlaces.descriptor(for: tab)
                return ShellCommand(target: .place(tab), title: place.title, keywords: placeKeywords(tab), glyph: place.glyph)
            }
        let space = spacePlaces.map { place in
            ShellCommand(target: .spacePlace(place), title: place.title, subtitle: "Space", glyph: place.symbolName)
        }
        return panes + space
    }

    static func chat(id: String, title: String, subtitle: String, isPinned: Bool) -> ShellCommand {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return ShellCommand(
            target: .chat(id),
            title: name.isEmpty ? untitledChat : name,
            subtitle: subtitle,
            glyph: isPinned ? "pin" : "bubble.left",
            isPinned: isPinned
        )
    }

    static func notebook(id: String, title: String, subtitle: String) -> ShellCommand {
        ShellCommand(target: .notebook(id), title: title, subtitle: subtitle, glyph: "book.closed")
    }

    static func page(id: String, title: String, subtitle: String) -> ShellCommand {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return ShellCommand(target: .page(id), title: name.isEmpty ? untitledPage : name, subtitle: subtitle, glyph: "doc.text")
    }

    static func source(id: String, title: String, subtitle: String, matchedByIndex: Bool) -> ShellCommand {
        ShellCommand(target: .source(id), title: title, subtitle: subtitle, glyph: "books.vertical", matchedByIndex: matchedByIndex)
    }

    static func setting(title: String, subtitle: String, keywords: [String], pane: SettingsPane) -> ShellCommand {
        ShellCommand(target: .settings(pane), title: title, subtitle: subtitle, keywords: keywords, glyph: "gearshape")
    }

    // MARK: - Ranking

    /// How well `command` answers `query`, lower is better; nil when it does
    /// not match. Case and accents are ignored.
    ///
    /// 0 the title itself · 1 a title that starts with the query · 2 every
    /// word of the query starts a word of the title · 3 the title holds every
    /// word · 4 every word starts a word of the title or the keywords · 5 the
    /// title, subtitle and keywords hold every word, or the library's index
    /// matched the source's text · 6 the letters of a one-word query appear in
    /// the title in order ("nwch" for New Chat).
    static func matchTier(_ command: ShellCommand, query: String) -> Int? {
        let wanted = fold(query)
        let terms = wanted.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return nil }
        let title = fold(command.title)
        if title == wanted { return 0 }
        if title.hasPrefix(wanted) { return 1 }
        let titleWords = words(of: title)
        if terms.allSatisfy({ term in titleWords.contains { $0.hasPrefix(term) } }) { return 2 }
        if terms.allSatisfy({ title.contains($0) }) { return 3 }
        let keywordText = command.keywords.map(fold).joined(separator: " ")
        let allWords = titleWords + words(of: keywordText)
        if terms.allSatisfy({ term in allWords.contains { $0.hasPrefix(term) } }) { return 4 }
        let haystack = [title, fold(command.subtitle), keywordText].joined(separator: " ")
        if terms.allSatisfy({ haystack.contains($0) }) || command.matchedByIndex { return 5 }
        if terms.count == 1, wanted.count >= 2, isSubsequence(wanted, of: title) { return 6 }
        return nil
    }

    /// The sections a search draws: each group's matches best first (equal
    /// matches keep the order given, so callers pass chats in the sidebar's
    /// order and Pages newest first), cut to the group's limit; the groups
    /// ordered by their best match, and by `ShellCommandGroup`'s order where
    /// two match equally well.
    static func sections(for commands: [ShellCommand], query: String) -> [ShellCommandSection] {
        var byGroup: [ShellCommandGroup: [(tier: Int, offset: Int, command: ShellCommand)]] = [:]
        for (offset, command) in commands.enumerated() {
            guard let tier = matchTier(command, query: query) else { continue }
            byGroup[command.searchGroup, default: []].append((tier, offset, command))
        }
        return byGroup
            .map { group, matches -> (best: Int, section: ShellCommandSection) in
                let sorted = matches.sorted { ($0.tier, $0.offset) < ($1.tier, $1.offset) }
                return (
                    sorted[0].tier,
                    ShellCommandSection(group: group, commands: sorted.prefix(group.searchLimit).map(\.command))
                )
            }
            .sorted { ($0.best, $0.section.group.rawValue) < ($1.best, $1.section.group.rawValue) }
            .map(\.section)
    }

    /// What the menu shows before anything is typed, as Codex's does: Quick
    /// actions, Pinned chats, Recent chats, then Recent Pages. `chats` come in
    /// the sidebar's order, `pages` newest first.
    static func emptyQuerySections(chats: [ShellCommand], pages: [ShellCommand]) -> [ShellCommandSection] {
        let quick = ShellAction.quickActions.map(command(for:))
        let pinned = Array(chats.filter(\.isPinned).prefix(ShellCommandGroup.pinnedChats.searchLimit))
        let recent = Array(chats.filter { !$0.isPinned }.prefix(ShellCommandGroup.recentChats.searchLimit))
        let recentPages = Array(pages.prefix(3))
        return [
            ShellCommandSection(group: .quickActions, commands: quick),
            ShellCommandSection(group: .pinnedChats, commands: pinned),
            ShellCommandSection(group: .recentChats, commands: recent),
            ShellCommandSection(group: .recentPages, commands: recentPages),
        ].filter { !$0.commands.isEmpty }
    }

    /// The row after (or before, for a negative `step`) `current` across all
    /// sections, wrapping at the ends; the first row when `current` is not
    /// among them.
    static func row(after current: String?, step: Int, in sections: [ShellCommandSection]) -> String? {
        let ids = sections.flatMap(\.commands).map(\.id)
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return ids.first }
        let next = (index + step % ids.count + ids.count) % ids.count
        return ids[next]
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func words(of text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var rest = haystack[...]
        for character in needle where !character.isWhitespace {
            guard let found = rest.firstIndex(of: character) else { return false }
            rest = rest[rest.index(after: found)...]
        }
        return true
    }
}

// MARK: - The ⌘/ sheet

/// One line of the Keyboard shortcuts sheet.
struct ShellShortcutEntry: Hashable, Sendable {
    let title: String
    let keys: [ShellKey]
    /// Written instead of `keys` for a range ("⌘1–⌘9").
    let keysText: String?

    init(_ title: String, _ keys: [ShellKey], keysText: String? = nil) {
        self.title = title
        self.keys = keys
        self.keysText = keysText
    }

    init(_ action: ShellAction) {
        self.init(action.title.replacingOccurrences(of: "…", with: ""), action.keys)
    }

    var keysDisplay: String {
        keysText ?? keys.map(\.display).joined(separator: " or ")
    }
}

/// The app's keys as the ⌘/ sheet lists them, in Codex's sections (General,
/// Navigation, Chat) and ForeverLM's own after them. Read-only, as Settings
/// holds only what a learner changes.
enum ShellKeyboardShortcuts {
    /// Keys bound outside `ShellAction`, which the menu bar reads from here.
    /// Each moved off a key Codex uses (⌥⌘A, ⌥⌘S) on 2026-10-13.
    static let atlas = [ShellKey("a", [.command, .control])]
    static let notebookSources = [ShellKey("s", [.command, .option, .control])]
    static let saveCanvasVersion = [ShellKey("s", [.command, .option, .shift])]

    static var sections: [(title: String, entries: [ShellShortcutEntry])] {
        [
            ("General", [
                ShellShortcutEntry(.commandMenu),
                ShellShortcutEntry(.keyboardShortcuts),
                ShellShortcutEntry(.settings),
                ShellShortcutEntry(.newWindow),
                ShellShortcutEntry("Close Window", [.command("w")]),
                ShellShortcutEntry("Enter Full Screen", [ShellKey("f", [.command, .control])]),
                ShellShortcutEntry(.zoomIn),
                ShellShortcutEntry(.zoomOut),
                ShellShortcutEntry(.resetZoom),
                ShellShortcutEntry("Quit ForeverLM", [.command("q")]),
            ]),
            ("Navigation", [
                ShellShortcutEntry(.back),
                ShellShortcutEntry(.forward),
                ShellShortcutEntry(.toggleSidebar),
                ShellShortcutEntry(.space),
                ShellShortcutEntry(.library),
                ShellShortcutEntry(.openReader),
                ShellShortcutEntry("Atlas (beta)", ShellKeyboardShortcuts.atlas),
            ]),
            ("Chat", [
                ShellShortcutEntry(.newChat),
                ShellShortcutEntry(.sideChat),
                ShellShortcutEntry(.quickChat),
                ShellShortcutEntry(.openChat),
                ShellShortcutEntry(.previousChat),
                ShellShortcutEntry(.nextChat),
                ShellShortcutEntry(.nextUnreadChat),
                ShellShortcutEntry("Go to Chat 1–9", [], keysText: "⌘1–⌘9"),
                ShellShortcutEntry("Open Recent Chat 1–6", [], keysText: "⌥⌘1–⌥⌘6"),
                ShellShortcutEntry(.renameChat),
                ShellShortcutEntry(.togglePinChat),
                ShellShortcutEntry(.markChatUnread),
                ShellShortcutEntry(.hideChat),
                ShellShortcutEntry(.copyChatLink),
                ShellShortcutEntry(.copyConversation),
                ShellShortcutEntry(.clearUnread),
                ShellShortcutEntry(.selectModel),
                ShellShortcutEntry("Find in Chat", [.command("f")]),
                ShellShortcutEntry("Find Next", [.command("g")]),
                ShellShortcutEntry("Find Previous", [ShellKey("g", [.command, .shift])]),
                ShellShortcutEntry("Side Question", [ShellKey(ShellKey.returnKey, .option)]),
            ].filter { !$0.keys.isEmpty || $0.keysText != nil }),
            ("Notebooks and Pages", [
                // The Space's own key: it works while the Space shows.
                ShellShortcutEntry("New Page (in the Space)", ShellAction.newPage.keys),
                ShellShortcutEntry(.addSources),
                ShellShortcutEntry("Show or Hide Sources", ShellKeyboardShortcuts.notebookSources),
                ShellShortcutEntry("Show Pages", [ShellKey("e", [.command, .shift])]),
                ShellShortcutEntry("Block Menu in a Page", [ShellKey("/", [.command, .option])]),
                ShellShortcutEntry("Save Canvas Version (beta)", ShellKeyboardShortcuts.saveCanvasVersion),
            ]),
            ("Reading", [
                ShellShortcutEntry("Find", [.command("f")]),
                ShellShortcutEntry("Go to Page", [ShellKey("g", [.command, .option])]),
            ]),
            ("Today", [
                ShellShortcutEntry(.planTheDay),
                ShellShortcutEntry(.dailyNotes),
                ShellShortcutEntry(.startPomodoro),
            ]),
        ]
    }
}
