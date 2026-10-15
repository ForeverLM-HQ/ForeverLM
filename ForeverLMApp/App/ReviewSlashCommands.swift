import SwiftUI

// MARK: - Chat slash commands

/// A `/` command the learner can type in the review chat composer to change a setting or
/// perform a quick action, mirroring the slash commands in Claude Code. Discovery happens
/// through the autocomplete popup; `ReviewSlashCommandParser` turns text into suggestions
/// and parses a submitted line into a command + argument.
struct ReviewSlashCommand: Identifiable, Equatable {
    enum Kind: Equatable {
        case goal
        case source
        case doc
        case site
        case sitePrompt
        /// Makes a short explainer video of a concept, in the Videos pane.
        case video
        /// Plans a course with the learner in this chat, then generates it
        /// (`CoursePlanningChat`) — what Generate in the Courses tab opens.
        case course
        /// Asks the chat for an animation of how something works, drawn from
        /// this chat's sources and saved under Animations.
        case animate
        case today
        /// Plan a day into the Mac's Calendar, in a conversation.
        case plan
        case review
        case notebook
        case new
        case model
        case settings
        case end
        case help
        /// Codex's thread verbs, on the chat that is open: rename it, pin
        /// it, hide it (ForeverLM's Hide is Codex's archive), fork it (Branch
        /// in New Chat over the whole thread), and set its reasoning effort.
        case rename
        case pin
        case hide
        case fork
        /// A side chat about the whole chat (Codex's /side).
        case side
        case reasoning
        /// One of the learner's own skills (chat-design.md, "Skills"): the
        /// command's name is the skill's, and the message goes to the chat
        /// with the skill's instructions beside it (`ChatSkillRequest`).
        case skill
    }

    /// An enumerable argument value offered as a second-level suggestion (e.g. Notebook names).
    struct Argument: Equatable {
        /// Token inserted into the composer, e.g. `openai`.
        let value: String
        /// Human label shown beside the token in the popup.
        let display: String
        /// The record this row stands for, when the row is a library item rather
        /// than a word — a source token or a Doc id. Two sources can share a
        /// title, so accepting such a row hands the command this identity and
        /// never the text; `nil` for a plain enumerable value like a Notebook name.
        let reference: String?

        init(value: String, display: String, reference: String? = nil) {
            self.value = value
            self.display = display
            self.reference = reference
        }
    }

    /// Where a command's argument rows come from once its name is typed.
    enum ArgumentSource: Equatable {
        /// A fixed list, narrowed by prefix as the learner types (Settings panes,
        /// Notebook titles).
        case fixed
        /// A search over the library, run for the text after the command by the
        /// pane that owns the data. The rows arrive already matched, so the
        /// parser shows them as they are (`ReviewSlashLiveArguments`).
        case search
    }

    let kind: Kind
    /// Command name without the leading slash, e.g. `notebook`.
    let name: String
    /// One-line description shown in the popup.
    let summary: String
    /// Placeholder shown after the name in the popup, e.g. `<query>`. `nil` means no argument.
    let argHint: String?
    /// Enumerable argument values offered after the command name is complete.
    let arguments: [Argument]
    let argumentSource: ArgumentSource

    init(
        kind: Kind,
        name: String,
        summary: String,
        argHint: String?,
        arguments: [Argument],
        argumentSource: ArgumentSource = .fixed
    ) {
        self.kind = kind
        self.name = name
        self.summary = summary
        self.argHint = argHint
        self.arguments = arguments
        self.argumentSource = argumentSource
    }

    var id: String { name }
    var takesArgument: Bool { argHint != nil }

    /// The `/name` row for one of the learner's skills. Its description is
    /// the popup's line, as it is the chat's cue for when the skill applies.
    static func skill(_ skill: SkillRecord) -> ReviewSlashCommand {
        ReviewSlashCommand(
            kind: .skill,
            name: skill.name,
            summary: skill.description,
            argHint: "[request]",
            arguments: []
        )
    }
    var searchesArguments: Bool { argumentSource == .search }

    func withArguments(_ arguments: [Argument]) -> ReviewSlashCommand {
        ReviewSlashCommand(
            kind: kind,
            name: name,
            summary: summary,
            argHint: argHint,
            arguments: arguments,
            argumentSource: argumentSource
        )
    }

    static let all: [ReviewSlashCommand] = [
        ReviewSlashCommand(
            kind: .goal,
            name: "goal",
            summary: "Set a learning goal",
            argHint: "[topic]",
            arguments: []
        ),
        ReviewSlashCommand(
            kind: .source,
            name: "source",
            summary: "Add a source from your library to this chat",
            argHint: "[search]",
            arguments: [],
            argumentSource: .search
        ),
        ReviewSlashCommand(
            kind: .doc,
            name: "page",
            summary: "Add one of your Pages to this chat",
            argHint: "[title]",
            arguments: [],
            argumentSource: .search
        ),
        // What /page was called while the feature was named Docs; kept so
        // the command typed from habit still works, as /clear is /new.
        ReviewSlashCommand(
            kind: .doc,
            name: "doc",
            summary: "Alias for /page",
            argHint: "[title]",
            arguments: [],
            argumentSource: .search
        ),
        ReviewSlashCommand(
            kind: .site,
            name: "site",
            summary: "Add one of your Sites to this chat",
            argHint: "[title]",
            arguments: [],
            argumentSource: .search
        ),
        ReviewSlashCommand(
            kind: .sitePrompt,
            name: "site-prompt",
            summary: "Write a prompt for Claude or Codex to build a Site from this chat",
            argHint: "[focus]",
            arguments: []
        ),
        ReviewSlashCommand(
            kind: .animate,
            name: "animate",
            summary: "Animate how something works, from this chat's sources",
            argHint: "[what]",
            arguments: []
        ),
        ReviewSlashCommand(
            kind: .video,
            name: "video",
            summary: "Make a short explainer video of a concept",
            argHint: "[concept]",
            arguments: []
        ),
        ReviewSlashCommand(
            kind: .course,
            name: "course",
            summary: "Plan a course with the chat, then generate it",
            argHint: "[topic]",
            arguments: []
        ),
        ReviewSlashCommand(
            kind: .today,
            name: "today",
            summary: "What is on the calendar right now",
            argHint: nil,
            arguments: []
        ),
        ReviewSlashCommand(
            kind: .plan,
            name: "plan",
            summary: "Plan a day into the calendar",
            argHint: "[today | tomorrow | request]",
            arguments: [
                Argument(value: "today", display: "Plan today"),
                Argument(value: "tomorrow", display: "Plan tomorrow"),
            ]
        ),
        ReviewSlashCommand(
            kind: .review,
            name: "review",
            summary: "Review the current sources or notebook",
            argHint: nil,
            arguments: []
        ),
        ReviewSlashCommand(
            kind: .notebook,
            name: "notebook",
            summary: "Switch to another notebook",
            argHint: "[name]",
            arguments: []
        ),
        ReviewSlashCommand(
            kind: .new,
            name: "new",
            summary: "Start a new, blank chat",
            argHint: nil,
            arguments: []
        ),
        ReviewSlashCommand(
            kind: .model,
            name: "model",
            summary: "Set this chat's model id",
            argHint: "<model-id>",
            arguments: []
        ),
        ReviewSlashCommand(
            kind: .settings,
            name: "settings",
            summary: "Open Settings",
            argHint: "[pane]",
            arguments: [
                Argument(value: "ai", display: "AI settings"),
                Argument(value: "billing", display: "Billing"),
                Argument(value: "usage", display: "AI Usage"),
                Argument(value: "sources", display: "Sources"),
                Argument(value: "plugins", display: "Plugins"),
                Argument(value: "mcp", display: "MCP settings"),
            ]
        ),
        ReviewSlashCommand(
            kind: .new,
            name: "clear",
            summary: "Alias for /new",
            argHint: nil,
            arguments: []
        ),
        ReviewSlashCommand(
            kind: .end,
            name: "end",
            summary: "Complete and record the current review",
            argHint: nil,
            arguments: []
        ),
        // Codex's thread verbs (learn.chatgpt.com/docs/reference/slash-commands).
        ReviewSlashCommand(
            kind: .rename,
            name: "rename",
            summary: "Rename this chat",
            argHint: "[title]",
            arguments: []
        ),
        ReviewSlashCommand(
            kind: .pin,
            name: "pin",
            summary: "Pin or unpin this chat",
            argHint: nil,
            arguments: []
        ),
        ReviewSlashCommand(
            kind: .hide,
            name: "hide",
            summary: "Hide this chat from Chats",
            argHint: nil,
            arguments: []
        ),
        ReviewSlashCommand(
            kind: .fork,
            name: "fork",
            summary: "Branch this chat into a new one",
            argHint: nil,
            arguments: []
        ),
        ReviewSlashCommand(
            kind: .side,
            name: "side",
            summary: "Ask about this chat in a side chat",
            argHint: nil,
            arguments: []
        ),
        ReviewSlashCommand(
            kind: .reasoning,
            name: "reasoning",
            summary: "Set how hard the model thinks",
            argHint: "<effort>",
            arguments: AIEffort.allCases.map {
                Argument(value: ReviewSlashCommandParser.effortToken($0), display: $0.displayName)
            }
        ),
        ReviewSlashCommand(
            kind: .help,
            name: "help",
            summary: "List the available slash commands",
            argHint: nil,
            arguments: []
        ),
    ]
}

// MARK: - `@` mentions of the library

/// What an `@` in the composer finds besides the connected plugins: the
/// learner's sources, Pages, Sites, chats and notebooks, as Codex's `@` finds
/// files, chats, pages and sites (`composer.atMentionList.*`, with the tabs
/// All · Chats · Pages). The library is ForeverLM's core, so sources lead.
/// Choosing one brings it into the chat through the path its slash command
/// or its drop already uses: a source the way `/source` adds it, a Page or a
/// Site the way `/page` and `/site` attach them, a notebook's sources the way
/// dropping a collection adds its sources. A chat has no such path, so it is
/// held beside the next message and its transcript rides with that message
/// as reference material (`chatReferenceContext`). The slash commands stay.
///
/// Pure text rules and ranking, shared by the popup, its key handling and the
/// pane that runs the search, so the three agree on what is being typed.
enum ChatMention {
    enum Kind: String, CaseIterable, Sendable {
        case source
        case page
        case site
        case chat
        case notebook

        /// The group heading the popup draws over this kind's rows.
        var groupTitle: String {
            switch self {
            case .source: return "Sources"
            case .page: return "Pages"
            case .site: return "Sites"
            case .chat: return "Chats"
            case .notebook: return "Notebooks"
            }
        }

        var systemImage: String {
            switch self {
            case .source: return "books.vertical"
            case .page: return "doc.text"
            case .site: return "globe"
            case .chat: return "bubble.left.and.bubble.right"
            case .notebook: return NotebookGlyph.systemImage
            }
        }
    }

    /// The popup's tabs, as Codex's `@` list has All · Chats · Pages · People.
    /// Sites are Pages with a page on the web, so they sit in the Pages tab.
    enum Tab: String, CaseIterable, Sendable {
        case all
        case sources
        case pages
        case chats
        case notebooks

        var title: String {
            switch self {
            case .all: return "All"
            case .sources: return "Sources"
            case .pages: return "Pages"
            case .chats: return "Chats"
            case .notebooks: return "Notebooks"
            }
        }

        func admits(_ kind: Kind) -> Bool {
            switch self {
            case .all: return true
            case .sources: return kind == .source
            case .pages: return kind == .page || kind == .site
            case .chats: return kind == .chat
            case .notebooks: return kind == .notebook
            }
        }

        /// Plugins are offered under All only, the way Codex lists them in
        /// its whole list and not under a category.
        var admitsPlugins: Bool { self == .all }

        /// What the popup says before anything is typed after the `@`.
        var emptyQueryLine: String {
            switch self {
            case .all: return "Type to search sources, Pages, chats and notebooks"
            case .sources: return "Type to search sources"
            case .pages: return "Type to search Pages and Sites"
            case .chats: return "Type to search chats"
            case .notebooks: return "Type to search notebooks"
            }
        }
    }

    /// One thing the popup offers. `reference` is what the add path takes:
    /// a source picker token (`source:<id>`, `book:<id>`), a Page's or Site's
    /// artifact id, a chat's session id or a notebook's id.
    struct Item: Equatable, Identifiable, Hashable, Sendable {
        let kind: Kind
        let reference: String
        let title: String
        let subtitle: String

        var id: String { "\(kind.rawValue).\(reference)" }
    }

    /// The rows a search produced, stamped with the query they answer, so a
    /// keystroke's stale rows never show under the next query.
    struct LiveResults: Equatable, Sendable {
        let query: String
        let items: [Item]

        func answers(_ query: String) -> Bool { self.query == query }
    }

    static let sigil: Character = "@"
    /// Rows per kind under All; a kind's own tab shows `rowsPerTab`.
    static let rowsPerKindInAll = 3
    static let rowsPerTab = 8

    /// The `@` query being typed at the very end of `text`: everything after
    /// an `@` that starts a word, up to the end, with no whitespace in it. Nil
    /// for a `/` command, an address (`zara@example.org`), or once a space
    /// follows: the mention is over and the popup has nothing to offer.
    static func pendingQuery(in text: String) -> (query: String, range: Range<String.Index>)? {
        guard !text.hasPrefix("/"), let last = text.last, !last.isWhitespace else { return nil }
        var start = text.endIndex
        while start > text.startIndex {
            let before = text.index(before: start)
            if text[before].isWhitespace { break }
            start = before
        }
        guard text[start] == sigil else { return nil }
        let query = String(text[text.index(after: start)...])
        // A second `@` inside the word is an address being typed, not a query.
        guard !query.contains(sigil) else { return nil }
        return (query, start..<text.endIndex)
    }

    /// `text` once a row is chosen for the pending query: the `@` and what was
    /// typed after it go, since what was chosen shows where it landed (the
    /// context chips, the chat chip above the field), and the learner goes
    /// on typing where the `@` was.
    static func removingPending(from text: String) -> String {
        guard let pending = pendingQuery(in: text) else { return text }
        return String(text[..<pending.range.lowerBound])
    }

    /// How well `title` answers `query`: 0 for the title itself, 1 for a
    /// title that starts with it, 2 for one with a word that does, 3 for one
    /// that holds every word of it somewhere; nil when it does not match.
    /// Case and accents are ignored.
    static func matchRank(title: String, query: String) -> Int? {
        let folded = fold(title)
        let wanted = fold(query)
        let terms = wanted.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return nil }
        if folded == wanted { return 0 }
        if folded.hasPrefix(wanted) { return 1 }
        let words = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if terms.allSatisfy({ term in words.contains { $0.hasPrefix(term) } }) { return 2 }
        if terms.allSatisfy({ folded.contains($0) }) { return 3 }
        return nil
    }

    /// `records` that match `query`, best match first; records that match
    /// equally keep the order given (callers pass them newest first).
    static func ranked<T>(_ records: [T], query: String, title: (T) -> String) -> [T] {
        records.enumerated()
            .compactMap { offset, record in
                matchRank(title: title(record), query: query).map { (rank: $0, offset: offset, record: record) }
            }
            .sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }
            .map(\.record)
    }

    /// The rows a tab shows, grouped by kind in `Kind`'s order: a few of each
    /// under All, more in a kind's own tab.
    static func rows(_ items: [Item], tab: Tab) -> [Item] {
        let limit = tab == .all ? rowsPerKindInAll : rowsPerTab
        return Kind.allCases.filter(tab.admits).flatMap { kind in
            items.filter { $0.kind == kind }.prefix(limit)
        }
    }

    /// The transcript of a chat the learner pointed at with `@`, as the
    /// reference material the next message carries. Turns run oldest first;
    /// when the whole chat is longer than `characterLimit`, the oldest turns
    /// are left out and the block says so, since the end of a chat is where
    /// it arrived. Names no id: the block is read by the model, never shown.
    static func chatReferenceContext(
        title: String,
        turns: [(speaker: String, text: String)],
        characterLimit: Int = 12_000
    ) -> String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let heading = "Referenced chat \u{201C}\(name.isEmpty ? "Untitled chat" : name)\u{201D}: the learner pointed at this earlier chat with @. Read it as background to their message."
        let lines = turns.compactMap { turn -> String? in
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : "\(turn.speaker): \(text)"
        }
        guard !lines.isEmpty else { return heading + "\n(The chat has no messages yet.)" }
        var kept: [String] = []
        var used = 0
        for line in lines.reversed() {
            let cost = line.count + 2
            if used + cost > characterLimit, !kept.isEmpty { break }
            kept.insert(line, at: 0)
            used += cost
        }
        var block = [heading]
        if kept.count < lines.count { block.append("(Earlier turns left out.)") }
        block.append(contentsOf: kept)
        return block.joined(separator: "\n\n")
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A single row in the composer's autocomplete popup — a `/` command, one of
/// its argument values, an `@` plugin mention, or something of the library
/// an `@` found.
struct ReviewSlashSuggestion: Identifiable, Equatable {
    enum Payload: Equatable {
        case command(ReviewSlashCommand)
        case argument(ReviewSlashCommand.Argument, command: ReviewSlashCommand)
        /// `@slack`, `@linear`, `@github`: the message is addressed to a
        /// connected workspace plugin, and the model reads it live
        /// (`ChatPluginRequest`). `completion` is the whole draft with the
        /// `@` being typed replaced by the mention, since the mention can sit
        /// anywhere in the text rather than only at its head like a command.
        case mention(ReviewComposerMention, completion: String)
        /// A source, Page, Site, chat or notebook an `@` found. `completion`
        /// is the draft with the `@` query taken out (`ChatMention`).
        case library(ChatMention.Item, completion: String)
    }

    let payload: Payload
    /// What a command row is typed with: `/`, or `$` for a skill asked for the
    /// way Codex's `$name` asks for one.
    var sigil: Character = ReviewSlashCommandParser.commandSigil

    var id: String {
        switch payload {
        case .command(let command): return "command.\(command.name)"
        case .argument(let argument, let command):
            return "arg.\(command.name).\(argument.reference ?? argument.value)"
        case .mention(let mention, _): return "mention.\(mention.id)"
        case .library(let item, _): return "library.\(item.id)"
        }
    }

    /// The plugin a mention row stands for, whose mark the row draws.
    var mentionedPlugin: ChatPlugin? {
        guard case .mention(let mention, _) = payload else { return nil }
        return mention.plugin
    }

    /// The library item an `@` row stands for.
    var libraryItem: ChatMention.Item? {
        guard case .library(let item, _) = payload else { return nil }
        return item
    }

    /// The heading the `@` popup groups this row under.
    var mentionGroupTitle: String? {
        switch payload {
        case .mention: return "Plugins"
        case .library(let item, _): return item.kind.groupTitle
        case .command, .argument: return nil
        }
    }

    /// The library record an accepted row stands for — a source token or a Doc
    /// id — when it stands for one. Its command runs on this directly rather
    /// than by round-tripping the title through the composer.
    var reference: (command: ReviewSlashCommand, reference: String)? {
        guard case .argument(let argument, let command) = payload,
              let reference = argument.reference else { return nil }
        return (command, reference)
    }

    /// Library rows read as prose — a title over an attribution — where a
    /// command or a fixed token reads as code.
    var isLibraryRow: Bool { reference != nil || libraryItem != nil }

    /// Primary text shown in the popup; monospaced unless `isLibraryRow`.
    var title: String {
        switch payload {
        case .command(let command):
            if let argHint = command.argHint {
                return "\(sigil)\(command.name) \(argHint)"
            }
            return "\(sigil)\(command.name)"
        case .argument(let argument, _):
            return argument.value
        case .mention(let mention, _):
            return mention.plugin.mentionToken
        case .library(let item, _):
            return item.title
        }
    }

    /// Secondary descriptive text shown after the title.
    var subtitle: String? {
        switch payload {
        case .command(let command): return command.summary
        case .argument(let argument, _): return argument.display
        case .mention(let mention, _): return mention.summary
        case .library(let item, _): return item.subtitle.isEmpty ? nil : item.subtitle
        }
    }

    /// Full composer text after accepting this suggestion.
    var completionText: String {
        switch payload {
        case .command(let command):
            return command.takesArgument ? "\(sigil)\(command.name) " : "\(sigil)\(command.name)"
        case .argument(let argument, let command):
            return "\(sigil)\(command.name) \(argument.value)"
        case .mention(_, let completion), .library(_, let completion):
            return completion
        }
    }

    /// Whether accepting should immediately submit (run) the command rather than wait for an argument.
    var runsImmediately: Bool {
        switch payload {
        case .command(let command): return !command.takesArgument
        case .argument: return true
        // The mention waits for the question, like a command with an argument;
        // a bare mention sent on purpose asks the plugin's default question.
        // A library row brings its item in and leaves the question to come.
        case .mention, .library: return false
        }
    }
}

/// The rows a library search produced for one `/` command and one query.
///
/// Searching the library is the pane's job — it owns the view model — but the
/// popup and the key handling both live in views that re-render per keystroke
/// without the pane. So the search result travels on `ReviewComposerDraft`,
/// stamped with the text it answers, and the parser only uses it while the
/// draft still asks the same question. Stale rows from the previous keystroke
/// therefore never flash under a new query.
struct ReviewSlashLiveArguments: Equatable {
    let commandName: String
    let query: String
    let arguments: [ReviewSlashCommand.Argument]

    func matches(commandName: String, query: String) -> Bool {
        self.commandName == commandName && self.query == query
    }
}

enum ReviewSlashCommandParser {
    /// The source ids a list of picker tokens names, in order and without repeats.
    ///
    /// Three spellings reach the chat: a bare source id (the Docs picker's
    /// chapter or ordinary row), `source:<id>` (the popup rows, which reuse the
    /// picker's search ids), and `book:<id>` for a whole book, which
    /// `chapterIDs` expands to the chapters that actually hold text.
    static func sourceIDs(
        fromTokens tokens: [String],
        chapterIDs: (String) -> [String]
    ) -> [String] {
        var seen = Set<String>()
        var ids: [String] = []
        func add(_ id: String) {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
            ids.append(trimmed)
        }
        for token in tokens {
            if token.hasPrefix(StudioViewModel.notepadGroundingBookPrefix) {
                let bookID = String(token.dropFirst(StudioViewModel.notepadGroundingBookPrefix.count))
                chapterIDs(bookID).forEach(add)
            } else if token.hasPrefix("source:") {
                add(String(token.dropFirst("source:".count)))
            } else {
                add(token)
            }
        }
        return ids
    }

    /// The search a draft is asking a `.search` command to run: the command and
    /// the text after its name, or `nil` when the draft is not such a command
    /// with its name complete. The query is trimmed, so `/source ` and
    /// `/source  ` are the same (empty) question.
    static func liveArgumentQuery(
        in text: String,
        commands: [ReviewSlashCommand] = ReviewSlashCommand.all
    ) -> (command: ReviewSlashCommand, query: String)? {
        guard text.hasPrefix("/"), !text.contains("\n") else { return nil }
        let body = text.dropFirst()
        guard let spaceIndex = body.firstIndex(of: " ") else { return nil }
        let name = String(body[..<spaceIndex]).lowercased()
        guard let command = commands.first(where: { $0.name == name }),
              command.searchesArguments else { return nil }
        let query = String(body[body.index(after: spaceIndex)...])
            .trimmingCharacters(in: .whitespaces)
        return (command, query)
    }

    /// The recognized command token at the start of a draft, including its leading slash.
    /// Kept separate from submission parsing so the composer can style only `/goal`, leaving
    /// the learner's topic or other free-form argument as ordinary text.
    static func commandPrefix(
        in text: String,
        commands: [ReviewSlashCommand] = ReviewSlashCommand.all
    ) -> (command: ReviewSlashCommand, range: Range<String.Index>)? {
        guard let sigil = text.first, sigil == commandSigil || sigil == skillSigil,
              !text.contains("\n") else { return nil }
        let end = text.firstIndex(where: { $0.isWhitespace }) ?? text.endIndex
        let range = text.startIndex..<end
        let name = text[text.index(after: text.startIndex)..<end].lowercased()
        let offered = sigil == skillSigil ? commands.filter { $0.kind == .skill } : commands
        guard let command = offered.first(where: { $0.name == name }) else { return nil }
        return (command, range)
    }

    /// What a command is typed with.
    static let commandSigil: Character = "/"
    /// `$name` asks for one of the learner's skills, as Codex's `$name` does;
    /// `/name` still does too.
    static let skillSigil: Character = "$"

    /// A draft that asks for a skill with `$`, read as the `/` command it is,
    /// over the skills alone: `$` names nothing else.
    private static func skillDraftAsCommand(
        _ text: String,
        commands: [ReviewSlashCommand]
    ) -> (text: String, skills: [ReviewSlashCommand])? {
        guard text.first == skillSigil else { return nil }
        let skills = commands.filter { $0.kind == .skill }
        return ("\(commandSigil)\(text.dropFirst())", skills)
    }

    /// A submitted `$name request`: the skill command and its request, or nil
    /// when `$` does not name one of the learner's skills (`$5 a month` is a
    /// message).
    static func parseSkillInvocation(
        _ text: String,
        commands: [ReviewSlashCommand] = ReviewSlashCommand.all
    ) -> (command: ReviewSlashCommand, argument: String?)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let asCommand = skillDraftAsCommand(trimmed, commands: commands) else { return nil }
        return parse(asCommand.text, commands: asCommand.skills)
    }

    /// The word `/reasoning` takes for an effort: its stored value, which the
    /// popup offers and the learner can type.
    static func effortToken(_ effort: AIEffort) -> String {
        effort.rawValue
    }

    /// The effort a `/reasoning` argument names: its stored value or its
    /// display name, in any case, spaces and hyphens ignored ("Extra High",
    /// "extra-high", "xhigh").
    static func effort(named token: String) -> AIEffort? {
        let squeezed = token.lowercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "_" }
        guard !squeezed.isEmpty else { return nil }
        return AIEffort.allCases.first { effort in
            effort.rawValue == squeezed
                || effort.displayName.lowercased().filter { !$0.isWhitespace } == squeezed
        }
    }

    /// Suggestions to show for the current composer text, or `[]` if the popup should be hidden.
    ///
    /// A draft that starts with `/` is a command; otherwise an `@` starting the
    /// word being typed offers `mentions` — the connected plugins — narrowed
    /// by prefix (`ChatPluginRequest.Mention`). `liveArguments` are the rows
    /// a library search produced for a `.search` command; they show only while
    /// they answer this exact draft.
    static func suggestions(
        for text: String,
        commands: [ReviewSlashCommand] = ReviewSlashCommand.all,
        mentions: [ReviewComposerMention] = [],
        liveArguments: ReviewSlashLiveArguments? = nil,
        liveMentions: ChatMention.LiveResults? = nil,
        mentionTab: ChatMention.Tab = .all
    ) -> [ReviewSlashSuggestion] {
        if let asCommand = skillDraftAsCommand(text, commands: commands) {
            return suggestions(for: asCommand.text, commands: asCommand.skills).map { row in
                var dollar = row
                dollar.sigil = skillSigil
                return dollar
            }
        }
        guard text.hasPrefix("/") else {
            return mentionSuggestions(for: text, mentions: mentions, tab: mentionTab)
                + librarySuggestions(for: text, liveMentions: liveMentions, tab: mentionTab)
        }
        guard !text.contains("\n") else { return [] }
        let body = String(text.dropFirst())

        guard let spaceIndex = body.firstIndex(of: " ") else {
            // Still typing the command name: filter by prefix.
            let prefix = body.lowercased()
            return commands
                .filter { $0.name.hasPrefix(prefix) }
                .map { .init(payload: .command($0)) }
        }

        // Command name is complete — offer enumerable argument values.
        let name = String(body[..<spaceIndex]).lowercased()
        guard let command = commands.first(where: { $0.name == name }) else { return [] }

        if command.searchesArguments {
            let query = String(body[body.index(after: spaceIndex)...])
                .trimmingCharacters(in: .whitespaces)
            guard let liveArguments, liveArguments.matches(commandName: command.name, query: query) else {
                return []
            }
            return liveArguments.arguments.map { .init(payload: .argument($0, command: command)) }
        }

        guard !command.arguments.isEmpty else { return [] }

        let token = String(body[body.index(after: spaceIndex)...])
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        let matches = command.arguments.filter {
            $0.value.lowercased().hasPrefix(token) || $0.display.lowercased().hasPrefix(token)
        }
        // Hide once the token already exactly names the only remaining value.
        if matches.count == 1, matches[0].value.lowercased() == token { return [] }
        return matches.map { .init(payload: .argument($0, command: command)) }
    }

    /// The `@` rows for the mention being typed at the end of `text`: every
    /// connected plugin right after a bare `@`, fewer as the name is typed,
    /// none once the mention is complete or when nothing is connected.
    static func mentionSuggestions(
        for text: String,
        mentions: [ReviewComposerMention],
        tab: ChatMention.Tab = .all
    ) -> [ReviewSlashSuggestion] {
        guard !mentions.isEmpty, tab.admitsPlugins else { return [] }
        let candidates = ChatPluginRequest.Mention.candidates(in: text, plugins: mentions.map(\.plugin))
        return candidates.compactMap { plugin in
            guard let mention = mentions.first(where: { $0.plugin == plugin }) else { return nil }
            return ReviewSlashSuggestion(payload: .mention(
                mention,
                completion: ChatPluginRequest.Mention.completing(text, with: plugin)
            ))
        }
    }

    /// The `@` rows of the library for the query being typed: what the
    /// pane's search found for exactly this query (`liveMentions`), grouped
    /// by kind and narrowed to `tab`. None for a bare `@`: the popup says
    /// what to type instead, as Codex's does.
    static func librarySuggestions(
        for text: String,
        liveMentions: ChatMention.LiveResults?,
        tab: ChatMention.Tab
    ) -> [ReviewSlashSuggestion] {
        guard let pending = ChatMention.pendingQuery(in: text), !pending.query.isEmpty,
              let liveMentions, liveMentions.answers(pending.query) else { return [] }
        let completion = ChatMention.removingPending(from: text)
        return ChatMention.rows(liveMentions.items, tab: tab).map {
            ReviewSlashSuggestion(payload: .library($0, completion: completion))
        }
    }

    /// Parses a submitted composer line into a known command + optional argument, or `nil` when the
    /// text is not a recognized slash command (so it can be sent as a normal message).
    static func parse(
        _ text: String,
        commands: [ReviewSlashCommand] = ReviewSlashCommand.all
    ) -> (command: ReviewSlashCommand, argument: String?)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), !trimmed.contains("\n") else { return nil }
        let body = trimmed.dropFirst()
        let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let nameSub = parts.first,
              let command = commands.first(where: { $0.name == String(nameSub).lowercased() })
        else { return nil }
        let argument = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        return (command, argument.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// The message `/site-prompt` sends the tutor: a request for a prompt the
    /// learner pastes into Claude, Codex or another assistant that has the
    /// ForeverLM plugin, so that assistant builds the Site with `save_site`
    /// from what this chat worked out.
    ///
    /// The tutor, not this code, writes the prompt, because the tutor holds the
    /// conversation and the attached source catalog; this text only fixes the
    /// shape. The two rules that matter to the other assistant are spelled out
    /// here: the prompt opens by naming the plugin, and each source travels
    /// as a `foreverlm://source/<id>` link — the one place a source id belongs
    /// in visible text, since it is what `save_site` turns into a source
    /// card. `focus` narrows the site to one angle of the chat; `notebookTitle`
    /// names the Notebook the new Site is filed under.
    static func sitePromptRequest(focus: String?, notebookTitle: String?) -> String {
        let focus = focus?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let notebook = notebookTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let subject = focus.isEmpty
            ? "from this conversation"
            : "from this conversation, focused on \(focus)"
        let filing = notebook.isEmpty
            ? ""
            : ", filed under my Notebook \u{201C}\(notebook)\u{201D} (it can find the id with list_notebooks and pass it as home_notebook_id)"
        return """
        Write a prompt I can paste into Claude or Codex so that it builds a ForeverLM site \(subject). Reply with the prompt alone, inside one fenced code block, so I can copy it in one go. Address the prompt to that assistant, in this shape:
        - Open with \u{201C}Use the ForeverLM plugin to make a ForeverLM site that explains \u{2026}\u{201D}, completing the sentence with the topic.
        - Say what the site must explain: the questions this chat worked through, the answers and distinctions it reached, where the sources disagree, what stays open, and the order to present it in. Be concrete enough that the site says what we worked out here, not a general overview of the topic.
        - List the library sources it should read and cite, each as a Markdown link [Title](foreverlm://source/SOURCE_ID) with the exact id from the attached source catalog, and say in a few words what each one contributes. Those link targets are the one place the ids belong: tell it to read each source through the plugin's get_source_content before writing, and to put each link on a line of its own in the page so ForeverLM draws it as a source card.
        - Tell it to save the site with save_site, as one page (html) or several files (files, with index.html at the root), with a short title\(filing). The site stays in my ForeverLM library.
        - End by asking it to reply with the site's title and to name anything it could not support from the sources.
        """
    }

    /// The message `/animate` sends: a request for an animation of how
    /// something works, drawn from the chat's sources and saved with
    /// `save_animation` linked to them. `focus` names what to animate; with
    /// none, the chat is asked to animate the mechanism the sources describe.
    static func animateRequest(focus: String?) -> String {
        let focus = focus?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let subject = focus.isEmpty
            ? "the mechanism the sources in this chat describe"
            : focus
        return """
        Make an interactive animation of how \(subject) works, drawn from the sources in this chat: every step labelled in words and placed where it happens, a play/pause control and a scrubber, and a toggle for each condition the sources compare. Save it with save_animation, linked to the sources you drew it from, with a two-sentence description of what it shows, and reply with its title and address.
        """
    }

    /// What `/plan` sends: the day-planning conversation.
    ///
    /// Which day is the one thing the command decides for itself, because by
    /// the afternoon "plan my day" means the next one, and a day planned the
    /// evening before is the one that starts well. `today` and `tomorrow` say it
    /// outright; anything else is passed through as the learner's own words.
    static func planDayRequest(_ argument: String?, now: Date = Date(), calendar: Calendar = .current) -> String {
        let trimmed = argument?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lowered = trimmed.lowercased()
        let opening: String
        switch lowered {
        case "today":
            opening = "Plan today on my clock."
        case "tomorrow":
            opening = "Plan tomorrow on my clock."
        case "":
            // Before the afternoon an unplanned today is still worth planning;
            // after it, the day is half spent and tomorrow is the useful one.
            opening = calendar.component(.hour, from: now) < DayPlan.planTomorrowFromHour
                ? "Plan today on my clock."
                : "Plan tomorrow on my clock."
        default:
            if DayPlan.isValidDateString(lowered) {
                // A date the app itself passed in.
                let today = DayPlan.dateString(for: now, calendar: calendar)
                let tomorrow = DayPlan.dateString(for: now.addingTimeInterval(86_400), calendar: calendar)
                switch lowered {
                case today: opening = "Plan today on my clock."
                case tomorrow: opening = "Plan tomorrow on my clock."
                default: opening = "Plan \(lowered) on my clock."
                }
            } else {
                // A day named some other way, or a constraint said in passing
                // ("monday", "I'm out until 11"). The words are the learner's
                // and the model reads which day they mean.
                opening = "Plan my clock. \(trimmed)"
            }
        }
        return """
        \(opening)

        My day is my Mac's Calendar. Read before you plan: get_calendar_events for that day, so you have what is already on it — meetings with other people stay where they are; the working log ForeverLM keeps of my work (list_working_notes: its running summary and the notes), and get_day_activity for the last few days, so you see what I have actually been reading, making and writing and where my hours went; then get_schedule and list_goals, which come second — a Goal is something you suggest from that pattern, not the spine of the day.

        Open with what you see in my log: the topics I keep returning to, a notebook I have been filling, a paper read without a review or any writing. Offer the next step for it — solidify it (a review or quiz), write about it, or turn it into a Goal. The log is kept up by the app from what I do; read it, do not edit it.

        Then do not ask me a question first: propose the whole day as a short list of blocks right away, taking what is fixed from the calendar and what the day is for from the log, and say in one line what you assumed so I can correct it. When I agree, add each block to my calendar with create_calendar_event, into the free stretches the calendar leaves. Put what each block is for in its notes — the next step, and the foreverlm:// link of the source it reads. Leave room for calls, email and anything I have to reach out to someone about — those are blocks too. Keep work blocks 90–120 minutes, leave a break when more than two hours remain, and end before my day does.
        """
    }

    static func parseSettingsPane(_ token: String) -> SettingsPane? {
        switch token.lowercased() {
        case "ai": return .aiChatModels
        case "billing", "plan", "subscription": return .aiBilling
        case "usage", "credits", "key": return .aiUsage
        case "mcp": return .mcp
        case "sources", "source": return .sources
        default: return nil
        }
    }

    /// Whether `/settings <token>` asks for the plugins, which are a place of
    /// their own rather than a Settings pane since 2026-10-13.
    static func namesPlugins(_ token: String) -> Bool {
        ["plugins", "plugin", "connectors", "connector", "external"].contains(token.lowercased())
    }
}

/// The floating autocomplete list shown above the composer while typing a `/`
/// command or an `@` mention.
struct ReviewSlashCommandPopup: View {
    let suggestions: [ReviewSlashSuggestion]
    let selectedIndex: Int
    /// The `@` popup's tabs and what it says while there is nothing to pick;
    /// nil for a `/` command.
    var mentionHeader: ReviewMentionPopupHeader? = nil
    let onSelect: (ReviewSlashSuggestion) -> Void

    /// Group headings name the kinds where a list mixes them: under All, and
    /// in Pages, which holds Sites too.
    private var showsGroupHeadings: Bool {
        guard let mentionHeader else { return false }
        return mentionHeader.tab == .all || mentionHeader.tab == .pages
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let mentionHeader {
                ReviewMentionTabs(selected: mentionHeader.tab, select: mentionHeader.selectTab)
                    .padding(.horizontal, 6)
                    .padding(.top, 2)
                    .padding(.bottom, 4)
            }
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                if showsGroupHeadings, let group = suggestion.mentionGroupTitle,
                   index == 0 || suggestions[index - 1].mentionGroupTitle != group {
                    Text(group)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textSelection(.disabled)
                        .padding(.horizontal, 10)
                        .padding(.top, index == 0 ? 2 : 8)
                        .padding(.bottom, 2)
                        .accessibilityAddTraits(.isHeader)
                }
                Button {
                    onSelect(suggestion)
                } label: {
                    HStack(spacing: 8) {
                        if let plugin = suggestion.mentionedPlugin {
                            // The plugin's brand mark lives here, on the row
                            // that offers it, rather than in the composer's chrome.
                            ChatPluginMark(plugin: plugin)
                        } else if let item = suggestion.libraryItem {
                            Image(systemName: item.kind.systemImage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 13)
                        }
                        Text(suggestion.title)
                            .font(suggestion.isLibraryRow ? .callout : .callout.monospaced())
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let subtitle = suggestion.subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                // A title is what the learner is scanning for; the
                                // attribution yields to it when the row is tight.
                                .layoutPriority(suggestion.isLibraryRow ? -1 : 0)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        index == selectedIndex ? Color.accentColor.opacity(0.18) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0))
            }
            if let line = mentionHeader?.statusLine {
                Text(line)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.disabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(4)
        .frame(width: mentionHeader == nil ? 360 : 400, alignment: .leading)
        .reviewGlassSurface(
            in: RoundedRectangle(cornerRadius: 10, style: .continuous),
            fallbackBorder: Color.secondary.opacity(0.18),
            shadowColor: .black.opacity(0.12),
            shadowRadius: 12,
            shadowY: 6
        )
    }
}

/// What the `@` popup draws above and below its rows: the tab chosen, and a
/// line while there is nothing to pick ("Type to search …", "Searching…",
/// "No results"), as Codex's `@` list says them.
struct ReviewMentionPopupHeader {
    let tab: ChatMention.Tab
    let statusLine: String?
    let selectTab: (ChatMention.Tab) -> Void

    /// The line for a pending `@` query: what to type before anything is,
    /// "Searching…" until the search for this query has answered, "No
    /// results" when it answered with nothing to show; nil when rows show.
    static func statusLine(
        query: String,
        tab: ChatMention.Tab,
        hasRows: Bool,
        hasAnswer: Bool
    ) -> String? {
        guard !hasRows else { return nil }
        if query.isEmpty { return tab.emptyQueryLine }
        return hasAnswer ? "No results" : "Searching…"
    }
}

/// The `@` popup's tabs: All · Sources · Pages · Chats · Notebooks, a row of
/// quiet capsules with the chosen one filled, as Codex's mention categories.
struct ReviewMentionTabs: View {
    let selected: ChatMention.Tab
    let select: (ChatMention.Tab) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ChatMention.Tab.allCases, id: \.self) { tab in
                Button {
                    select(tab)
                } label: {
                    Text(tab.title)
                        .font(.caption.weight(tab == selected ? .semibold : .regular))
                        .foregroundStyle(tab == selected ? .primary : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            tab == selected ? Color.primary.opacity(0.08) : Color.clear,
                            in: Capsule()
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.hoverWash(in: Capsule(), opacity: 0.08))
                .accessibilityAddTraits(tab == selected ? .isSelected : [])
                .accessibilityIdentifier("mac.chatMentionTab.\(tab.rawValue)")
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mention categories")
    }
}
