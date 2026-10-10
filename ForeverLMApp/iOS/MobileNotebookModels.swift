import Foundation
#if os(macOS)
@testable import ForeverLM
#endif

// The iPhone's notebooks, the parts with no view in them (docs/notebooks-design.md,
// "iPhone"): the chat checkboxes' synced rows and the context notebooks they
// put in, the whole-source grounding of a
// notebook chat, Home's order, the notebook a cold launch reopens, the
// foreverlm:// links the phone follows, the Docs a notebook lists, the chats
// it lists, what belongs to a notebook and the order of what it made, and the
// models a chat may pick. Foundation-only and compiled into the macOS unit
// tests beside `MobileCloudSourceModels.swift`, so each rule is pinned against
// the Mac's own (`NotebookChatSelection`, `NotebookChatContext`, `PreferenceStore`,
// `CloudKitArtifactPayload`, `ArtifactRecord.section`, `NotebookMembership`,
// `NotebookOutputs.ordered`); a notebook's cards are the Mac's own
// `MemoryCardScope`.

// MARK: - Synced preference values

/// How a synced Preference row carries its value: `{"v": value}` as an XML
/// property list, the encoding of the Mac's `PreferenceStore.encodePlist` and
/// `decodePlist`, so a row the phone writes is byte for byte the row the Mac
/// would write for the same value. `MobileModelPreferenceStore` writes and
/// reads every row through these two.
enum MobilePreferencePlist {
    static func encode(_ value: Any) -> String? {
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: ["v": value],
            format: .xml,
            options: 0
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The value of an XML row; nil for an empty or unreadable one, which the
    /// Mac treats as "remove this key".
    static func decode(_ xml: String) -> Any? {
        guard !xml.isEmpty, let data = xml.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        else { return nil }
        return (plist as? [String: Any])?["v"]
    }
}

// MARK: - Chat checkboxes

/// Which sources a notebook's chats read, as the Mac's `NotebookChatSelection`
/// keeps it: the member's two synced rows per notebook — the unticked sources
/// (`notebook.chatExcluded.<notebookID>`) and the context notebooks put in
/// (`notebook.chatContextNotebooks.<notebookID>`), each a sorted `[String]`,
/// no row when empty — read by the Mac's own rule (`NotebookChatContext`,
/// compiled into the phone). The chats read the notebook's own sources, then
/// those of each context notebook the member put in, minus the unticked; a
/// linked notebook alone reads nothing. The rule runs on the Mac's ids
/// (`poolSourceIDs`), so a box ticked on the phone reads the same on the Mac
/// and the other way round (`MobileNotebookTests` runs the shared vectors
/// through it).
enum MobileNotebookChatSelection {
    typealias Selection = NotebookChatContext.Selection

    static let preferenceKeyPrefix = "notebook.chatExcluded."

    /// The unticked row's key.
    static func preferenceKey(notebookID: String) -> String {
        preferenceKeyPrefix + notebookID
    }

    /// The context notebooks' row's key, the Mac's.
    static func contextNotebooksKey(notebookID: String) -> String {
        NotebookChatContext.preferenceKey(notebookID: notebookID)
    }

    // MARK: Pools

    /// The notebook's own sources as the rows name them.
    static func own(of notebook: MobileCloudNotebook) -> [String] {
        notebook.poolSourceIDs
    }

    /// Its context notebooks as the rule reads them: one per link, in link
    /// order, each with its sources as the rows name them; a link this phone
    /// has no record of has none, and its id still counts as linked.
    static func linked(of notebook: MobileCloudNotebook) -> [NotebookChatContext.ContextNotebook] {
        let held = Dictionary(
            notebook.contextNotebooks.map { ($0.id, $0.poolSourceIDs) },
            uniquingKeysWith: { first, _ in first }
        )
        return notebook.relatedNotebookIDs.filter { $0 != notebook.id }.map { id in
            NotebookChatContext.ContextNotebook(id: id, sourceIDs: held[id] ?? [])
        }
    }

    /// What the chats draw on: its own sources, then each context notebook
    /// put in, in link order, each once.
    static func chatPool(of notebook: MobileCloudNotebook, selection: Selection) -> [String] {
        NotebookChatContext.chatPool(own: own(of: notebook), linked: linked(of: notebook), selection: selection)
    }

    /// Every source a box can stand for, its context notebooks' put in or
    /// not: what the unticked row is kept to.
    static func linkedPool(of notebook: MobileCloudNotebook) -> [String] {
        NotebookChatContext.linkedPool(own: own(of: notebook), linked: linked(of: notebook))
    }

    /// What a new chat, a voice conversation or Review me reads: the chat
    /// pool minus the unticked, by the rows' ids (a source this phone holds
    /// under another id by both).
    static func chatSourceIDs(of notebook: MobileCloudNotebook, selection: Selection) -> [String] {
        NotebookChatContext.chatSourceIDs(own: own(of: notebook), linked: linked(of: notebook), selection: selection)
    }

    /// A pool in its own (study) order, minus the unticked.
    static func chatSourceIDs(pool: [String], excluded: Set<String>) -> [String] {
        excluded.isEmpty ? pool : pool.filter { !excluded.contains($0) }
    }

    // MARK: Changes

    /// One tap's change to the two rows.
    enum Change: Equatable, Sendable {
        /// A source row's box; `through` names the context notebook whose
        /// group the row is in.
        case sources([String], inChat: Bool, through: String?)
        /// A context notebook's own box.
        case contextNotebooks([String], inChat: Bool)
        /// Add a Notebook to Context: in the chats, its sources' boxes as
        /// they were.
        case putIn([String])
        /// Select all: every source the chats draw on ticked or unticked; the
        /// context notebooks stay in or out as they were.
        case all(inChat: Bool)
    }

    /// The rows after `change`, by the Mac's rule (`NotebookChatContext`).
    static func applying(
        _ change: Change,
        own: [String],
        linked: [NotebookChatContext.ContextNotebook],
        to selection: Selection
    ) -> Selection {
        switch change {
        case .sources(let sourceIDs, let inChat, let through):
            return NotebookChatContext.settingSources(
                sourceIDs, inChat: inChat, through: through, own: own, linked: linked, selection: selection
            )
        case .contextNotebooks(let notebookIDs, let inChat):
            return NotebookChatContext.settingContextNotebooks(
                notebookIDs, inChat: inChat, linked: linked, selection: selection
            )
        case .putIn(let notebookIDs):
            return NotebookChatContext.puttingIn(notebookIDs, linked: linked, selection: selection)
        case .all(let inChat):
            let pool = NotebookChatContext.chatPool(own: own, linked: linked, selection: selection)
            return NotebookChatContext.settingSources(
                pool, inChat: inChat, own: own, linked: linked, selection: selection
            )
        }
    }

    /// The rows as they are written (`NotebookChatContext.stored`): sorted,
    /// the unticked kept to the linked pool, and the context notebooks as
    /// they are, since this phone's links can lag the rows. An empty array
    /// removes its row.
    static func stored(
        _ selection: Selection,
        own: [String],
        linked: [NotebookChatContext.ContextNotebook]
    ) -> Selection {
        let rows = NotebookChatContext.stored(selection, own: own, linked: linked)
        return Selection(excluded: Set(rows.excluded), contextNotebookIDs: Set(rows.contextNotebookIDs))
    }

    /// A row's value as it is written, or nil when the row is removed
    /// instead: an empty array is no row at all.
    static func rowValueXML(excluded: [String]) -> String? {
        excluded.isEmpty ? nil : MobilePreferencePlist.encode(excluded)
    }

    /// The exclusion after `arriving` joined the notebook: their ids leave it,
    /// so an untick left from when a source last left the notebook never
    /// outlives its return (the Mac's `NotebookChatSelection.arrivalsToTick`).
    /// Sorted, as the Mac writes it.
    static func afterArrivals(_ current: Set<String>, arriving: [String]) -> [String] {
        current.subtracting(arriving).sorted()
    }

    /// Ticks `sourceIDs` in `notebookID`'s row after they joined the notebook,
    /// by whatever route the phone added them: reads the row, drops them, and
    /// writes only a change, an empty exclusion as the row's removal. No row,
    /// or a row naming none of them, is left alone. True when it wrote.
    @discardableResult
    static func tickArrivals(
        _ sourceIDs: [String],
        notebookID: String,
        read: (String) async throws -> [String]?,
        write: (String, [String]) async throws -> Void
    ) async throws -> Bool {
        guard !sourceIDs.isEmpty else { return false }
        let key = preferenceKey(notebookID: notebookID)
        guard let row = try await read(key) else { return false }
        let current = Set(row)
        let next = afterArrivals(current, arriving: sourceIDs)
        guard next.count != current.count else { return false }
        try await write(key, next)
        return true
    }
}

/// The state of a box that stands for several sources (Select all, a context
/// notebook's box): every one ticked, none, or some.
enum MobileNotebookTickState: Equatable, Sendable {
    case checked
    case mixed
    case unchecked

    static func of(ticked: Int, total: Int) -> MobileNotebookTickState {
        if total > 0, ticked >= total { return .checked }
        return ticked > 0 ? .mixed : .unchecked
    }
}

/// A context notebook's group under a notebook's own sources, as this phone
/// lists it: the notebook, and its sources this phone has, spoken scripts
/// left out as the notebook's own rows leave them.
struct MobileNotebookContextGroup: Identifiable, Equatable, Sendable {
    let notebook: MobileCloudContextNotebook
    let sources: [MobileCloudSource]

    var id: String { notebook.id }
}

/// A notebook's boxes as one draw shows them: its own sources and context
/// notebooks with the member's two rows, read into sets once so every row
/// asks in constant time while the list redraws.
struct MobileNotebookChatBoard: Sendable {
    let selection: NotebookChatContext.Selection
    let own: [String]
    let linked: [NotebookChatContext.ContextNotebook]
    private let chatPool: Set<String>
    private let linkedPool: Set<String>

    init(own: [String], linked: [NotebookChatContext.ContextNotebook], selection: NotebookChatContext.Selection) {
        self.selection = selection
        self.own = own
        self.linked = linked
        chatPool = Set(NotebookChatContext.chatPool(own: own, linked: linked, selection: selection))
        linkedPool = Set(NotebookChatContext.linkedPool(own: own, linked: linked))
    }

    init(notebook: MobileCloudNotebook, selection: NotebookChatContext.Selection) {
        self.init(
            own: MobileNotebookChatSelection.own(of: notebook),
            linked: MobileNotebookChatSelection.linked(of: notebook),
            selection: selection
        )
    }

    /// Whether a new chat reads `sourceID`: in the chat pool and not
    /// unticked. A source no pool holds reads ticked, as on the Mac: it
    /// would arrive so.
    func isInChat(_ sourceID: String) -> Bool {
        guard !selection.excluded.contains(sourceID) else { return false }
        return chatPool.contains(sourceID) || !linkedPool.contains(sourceID)
    }

    /// Whether the chats read the context notebook `id`'s sources.
    func isInChats(contextNotebook id: String) -> Bool {
        selection.contextNotebookIDs.contains(id) && linked.contains { $0.id == id }
    }

    /// A context notebook's own box, counting the sources its group lists
    /// (`shown`): out of the chats it is clear; in, ticked while none of
    /// them is unticked, mixed while some are, clear when all are. One in
    /// with nothing listed here yet is ticked, so its box takes it out.
    func state(ofContextNotebook id: String, shown: [String]) -> MobileNotebookTickState {
        let listed = Set(shown)
        guard let tally = NotebookChatContext.tally(
            of: id,
            linked: linked,
            selection: selection,
            counts: { listed.contains($0) }
        ) else { return .unchecked }
        return tally.total == 0 ? .checked : MobileNotebookTickState.of(ticked: tally.ticked, total: tally.total)
    }

    /// What the chats draw on as this phone lists it: the notebook's own
    /// rows, then the rows of each context notebook in its chats, in link
    /// order, each source once. "9 of 13 in chat" and Select all count these.
    func chatPoolSources(own ownRows: [MobileCloudSource], groups: [MobileNotebookContextGroup]) -> [MobileCloudSource] {
        var seen = Set<String>()
        var rows = ownRows.filter { seen.insert($0.id).inserted }
        for group in groups where isInChats(contextNotebook: group.id) {
            rows.append(contentsOf: group.sources.filter { seen.insert($0.id).inserted })
        }
        return rows
    }

    /// What a new chat reads, as rows this phone has: those of the chat pool
    /// whose box is ticked, in its order.
    func chatSources(own ownRows: [MobileCloudSource], groups: [MobileNotebookContextGroup]) -> [MobileCloudSource] {
        chatPoolSources(own: ownRows, groups: groups).filter { isInChat($0.id) }
    }
}

/// "9 of 13 in chat" for a notebook's boxes: the rows its chats draw on as
/// this phone lists them — its own, and those of each context notebook in its
/// chats — and how many a new chat reads; Select all's box follows it. Before
/// the rows are read there is no tally, only the notebook's own count.
struct MobileNotebookChatTally: Equatable, Sendable {
    let inChat: Int
    let total: Int
    let isLoaded: Bool

    init(board: MobileNotebookChatBoard?, own: [MobileCloudSource], groups: [MobileNotebookContextGroup]) {
        guard let board else {
            inChat = 0
            total = 0
            isLoaded = false
            return
        }
        let rows = board.chatPoolSources(own: own, groups: groups)
        inChat = rows.filter { board.isInChat($0.id) }.count
        total = rows.count
        isLoaded = true
    }

    var state: MobileNotebookTickState {
        isLoaded ? MobileNotebookTickState.of(ticked: inChat, total: total) : .unchecked
    }

    /// Whether Select all has rows to stand for: the tally's once read, the
    /// notebook's own until then.
    func hasRows(own ownCount: Int) -> Bool {
        isLoaded ? total > 0 : ownCount > 0
    }

    /// The Sources tab's line: "13 sources · 9 in chat", or the notebook's own
    /// count while the rows are unread or the chats draw on nothing.
    func sourcesLine(own ownCount: Int) -> String {
        guard isLoaded, total > 0 else { return Self.label(ownCount) }
        return "\(Self.label(total)) · \(inChat) in chat"
    }

    /// The chat's Sources sheet's line: "9 of 13 in chat".
    func ofLine(own ownCount: Int) -> String {
        guard isLoaded, total > 0 else { return Self.label(ownCount) }
        return "\(inChat) of \(total) in chat"
    }

    static func label(_ count: Int) -> String {
        count == 1 ? "1 source" : "\(count) sources"
    }
}

/// The notebooks Add a Notebook to Context offers: every other notebook the
/// phone lists that this one does not link to yet, in Home's order.
enum MobileNotebookContextPicker {
    static func candidates(for notebook: MobileCloudNotebook, in notebooks: [MobileCloudNotebook]) -> [MobileCloudNotebook] {
        let linked = Set(notebook.relatedNotebookIDs)
        return notebooks.filter { $0.id != notebook.id && !$0.isArchived && !linked.contains($0.id) }
    }

    static func hasCandidates(for notebook: MobileCloudNotebook, in notebooks: [MobileCloudNotebook]) -> Bool {
        let linked = Set(notebook.relatedNotebookIDs)
        return notebooks.contains { $0.id != notebook.id && !$0.isArchived && !linked.contains($0.id) }
    }
}

// MARK: - Grounding a notebook chat

/// What a notebook chat reads: the ticked sources, whole, in the notebook's
/// order, as many as fit the character budget. A source is never cut to fit:
/// one that does not fit, or whose text has not reached the phone, is listed
/// as in the notebook and not loaded, and the composer says so.
enum MobileNotebookChatGrounding {
    /// The characters of source text one notebook chat carries — the reading
    /// chat's own bound (`MobileStreamingChat.maxSourceCharacters`), which a
    /// whole source must fit inside instead of being cut to it.
    static let characterBudget = 240_000

    /// One ticked source: its id and the length of its text, nil when its text
    /// could not be read on this phone.
    struct Candidate: Equatable, Sendable {
        let sourceID: String
        let characterCount: Int?
    }

    enum Reason: Equatable, Sendable {
        /// Whole, it does not fit beside the sources loaded before it.
        case doesNotFit
        /// Its text has not reached this phone.
        case textUnavailable
    }

    struct NotLoaded: Equatable, Sendable {
        let sourceID: String
        let reason: Reason
    }

    struct Plan: Equatable, Sendable {
        let loaded: [String]
        let notLoaded: [NotLoaded]

        var tickedCount: Int { loaded.count + notLoaded.count }
        var doesNotFitCount: Int { notLoaded.filter { $0.reason == .doesNotFit }.count }
        var unavailableCount: Int { notLoaded.filter { $0.reason == .textUnavailable }.count }
        var isComplete: Bool { notLoaded.isEmpty }
    }

    /// Whole sources in order while they fit; one that does not is passed over
    /// and a later, shorter one may still be loaded. Nothing is ever cut.
    static func plan(_ candidates: [Candidate], budget: Int = characterBudget) -> Plan {
        var remaining = max(0, budget)
        var loaded: [String] = []
        var notLoaded: [NotLoaded] = []
        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate.sourceID).inserted {
            guard let count = candidate.characterCount else {
                notLoaded.append(NotLoaded(sourceID: candidate.sourceID, reason: .textUnavailable))
                continue
            }
            if count <= remaining {
                loaded.append(candidate.sourceID)
                remaining -= count
            } else {
                notLoaded.append(NotLoaded(sourceID: candidate.sourceID, reason: .doesNotFit))
            }
        }
        return Plan(loaded: loaded, notLoaded: notLoaded)
    }

    /// Whether a source of `wordCount` words (the Mac's stored count) is
    /// certainly longer than `remaining` characters, so its text need not be
    /// downloaded to know it does not fit. W words take at least 2W - 1
    /// characters (one letter each, one space between), so the answer is
    /// never yes for a source that would have fit.
    static func certainlyExceeds(wordCount: Int?, remaining: Int) -> Bool {
        guard let wordCount, wordCount > 0 else { return false }
        return 2 * wordCount - 1 > remaining
    }

    /// That lower bound, as the length a passed-over source is planned with.
    static func minimumCharacters(wordCount: Int) -> Int {
        max(0, 2 * wordCount - 1)
    }

    /// The composer's line when not every ticked source is read; nil when all are.
    static func composerNotice(_ plan: Plan) -> String? {
        guard !plan.isComplete else { return nil }
        var parts: [String] = []
        if plan.doesNotFitCount > 0 {
            parts.append("Reads \(plan.loaded.count) of \(plan.tickedCount) ticked sources; untick some to fit the rest.")
        }
        if plan.unavailableCount > 0 {
            parts.append(plan.unavailableCount == 1
                ? "1 source's text has not reached this iPhone yet."
                : "\(plan.unavailableCount) sources' text has not reached this iPhone yet.")
        }
        return parts.joined(separator: " ")
    }
}

/// The system prompt of a notebook chat on the phone: the notebook's
/// instructions, then every loaded source whole, then the sources it holds
/// and could not load. The sources ride the system prompt so the prompt cache
/// keeps them across turns, as the reading chat's single source does.
enum MobileNotebookChatPrompt {
    struct LoadedSource: Sendable {
        let source: MobileCloudSource
        let text: String
    }

    struct UnloadedSource: Sendable {
        let source: MobileCloudSource
        let reason: MobileNotebookChatGrounding.Reason
    }

    static func system(
        notebookTitle: String,
        instructions: String?,
        loaded: [LoadedSource],
        notLoaded: [UnloadedSource]
    ) -> String {
        let title = notebookTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        var sections: [String] = []
        sections.append("""
        You are the chat of a Notebook in ForeverLM. The learner is on an iPhone or iPad, asking about the Notebook's sources below.

        How to answer:
        - The sources below are your material. Answer from them and say which source each point comes from.
        - Cite a source as a Markdown link to its address, [Title](foreverlm://source/ID), with the exact ID given above its text. A citation opens the source on the learner's device.
        - If the sources do not cover what was asked, say so plainly, or answer from general knowledge only after clearly labelling it as outside the sources. Never invent detail and never attribute anything to a source that is not in it.
        - The sources under "In the Notebook, not loaded" are in the Notebook but not in this chat. If a question needs one, say so, and that unticking other sources in the Sources tab makes room for it.
        - Be concise but complete: answer the actual question first, then add only the context that earns its place.
        - Markdown is rendered, so use it where it helps readability.

        Notebook: \(title.isEmpty ? "Untitled" : title)
        """)
        if let instructions = instructions?.trimmingCharacters(in: .whitespacesAndNewlines), !instructions.isEmpty {
            sections.append("""
            The learner's instructions for chats in this Notebook:
            \(instructions)
            """)
        }
        for (index, item) in loaded.enumerated() {
            let number = index + 1
            sections.append("""
            --- BEGIN SOURCE \(number) ---
            ID: \(item.source.id)
            Title: \(sourceTitle(item.source))
            Type: \(item.source.sourceType)
            \(item.text)
            --- END SOURCE \(number) ---
            """)
        }
        if loaded.isEmpty {
            sections.append("No source is loaded in this chat.")
        }
        if !notLoaded.isEmpty {
            let lines = notLoaded.map { item in
                let why = switch item.reason {
                case .doesNotFit: "too long to load beside the others"
                case .textUnavailable: "its text has not reached this device"
                }
                return "- \(sourceTitle(item.source)) (ID: \(item.source.id)): \(why)"
            }
            sections.append("--- IN THE NOTEBOOK, NOT LOADED ---\n" + lines.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    private static func sourceTitle(_ source: MobileCloudSource) -> String {
        let title = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled" : title
    }

    /// A notebook chat's title, as the Mac and the Chat tab list it: its
    /// first message on one line, shortened at a word past 80 characters,
    /// else the notebook's name. A notebook holds many chats, so the
    /// notebook's name alone would not tell them apart.
    static func chatTitle(firstQuestion: String?, fallback: String) -> String {
        let line = (firstQuestion ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !line.isEmpty else { return fallback }
        guard line.count > 80 else { return line }
        let cut = String(line.prefix(80))
        let atWord = cut.range(of: " ", options: .backwards).map { String(cut[..<$0.lowerBound]) } ?? cut
        return atWord + "…"
    }
}

// MARK: - Home's order

/// Notebooks on Home, most recent first: the later of the notebook's own
/// change and the end of its latest chat, so the notebook just worked in
/// leads even when only its chat moved.
enum MobileNotebookOrdering {
    static func lastActivity(of notebook: MobileCloudNotebook, lastChatAt: [String: Date]) -> Date {
        max(notebook.updatedAt, lastChatAt[notebook.id] ?? .distantPast)
    }

    static func sorted(_ notebooks: [MobileCloudNotebook], lastChatAt: [String: Date]) -> [MobileCloudNotebook] {
        notebooks.sorted { lhs, rhs in
            let left = lastActivity(of: lhs, lastChatAt: lastChatAt)
            let right = lastActivity(of: rhs, lastChatAt: lastChatAt)
            if left != right { return left > right }
            let byTitle = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if byTitle != .orderedSame { return byTitle == .orderedAscending }
            return lhs.id < rhs.id
        }
    }
}

// MARK: - Opening in the last notebook

/// The phone opens in the notebook the learner last worked in, pushed over
/// Home on a cold launch so Back is the home (decisions-v5). Remembered on
/// this device only: which notebook a phone shows is not the account's.
enum MobileNotebookResume {
    static let defaultsKey = "ios.notebooks.lastOpenedNotebookID"

    /// The notebook to reopen: the remembered one while it is still a current
    /// notebook here; nil (Home) for a new learner, or one since archived or
    /// deleted.
    static func restoredNotebookID(stored: String?, notebooks: [MobileCloudNotebook]) -> String? {
        guard let stored = stored?.trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty,
              let notebook = notebooks.first(where: { $0.id == stored }),
              !notebook.isArchived else { return nil }
        return notebook.id
    }
}

/// Where the last notebook is remembered: this device's defaults, never a
/// synced row. A test passes its own suite.
struct MobileLastNotebookStore {
    let defaults: UserDefaults

    static var standard: MobileLastNotebookStore { MobileLastNotebookStore(defaults: .standard) }

    var notebookID: String? {
        if let stored = defaults.string(forKey: MobileNotebookResume.defaultsKey) { return stored }
        // Remembered before a notebook stopped being called a project.
        guard let retired = defaults.string(forKey: "ios.notebooks.lastOpenedProjectID") else { return nil }
        defaults.set(retired, forKey: MobileNotebookResume.defaultsKey)
        defaults.removeObject(forKey: "ios.notebooks.lastOpenedProjectID")
        return retired
    }

    func remember(_ notebookID: String) {
        guard defaults.string(forKey: MobileNotebookResume.defaultsKey) != notebookID else { return }
        defaults.set(notebookID, forKey: MobileNotebookResume.defaultsKey)
    }

    /// Forgets the notebook when it is the one remembered (archived or
    /// deleted from this phone).
    func forget(_ notebookID: String) {
        guard defaults.string(forKey: MobileNotebookResume.defaultsKey) == notebookID else { return }
        defaults.removeObject(forKey: MobileNotebookResume.defaultsKey)
    }
}

// MARK: - Links

/// The foreverlm:// addresses the phone follows: the widget's two, a
/// notebook (`foreverlm://notebook/<id>`, which the Mac writes into calendar
/// notes and pages, and the older `foreverlm://project/<id>` they may still hold), a source (`foreverlm://source/<id>`, a chat's
/// citation) and a page (`foreverlm://doc/<id>`, a page's link to another and
/// its Copy Link). The same reading as the Mac's `StudioEntityLink.parse`: the
/// host names the kind, the first path component, percent-decoded and
/// trimmed, is the id.
enum MobileDeepLink: Equatable, Hashable, Sendable {
    case today
    case review
    case notebook(String)
    case source(String)
    case doc(String)

    static let productScheme = "foreverlm"

    static func parse(_ url: URL) -> MobileDeepLink? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == productScheme || scheme == ForeverLMRuntimeIdentity.urlScheme.lowercased(),
              let host = url.host?.lowercased() else { return nil }
        switch host {
        case "today": return .today
        case "review": return .review
        case "notebook", "project", "source", "doc":
            guard let raw = url.pathComponents.dropFirst().first,
                  let id = raw.removingPercentEncoding?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty else { return nil }
            switch host {
            case "source": return .source(id)
            case "doc": return .doc(id)
            default: return .notebook(id)
            }
        default:
            return nil
        }
    }
}

// MARK: - The shell's routes

/// Where the shell's stack can go. Typed, so a link and the cold launch can
/// push a notebook or a source the same way a tap does.
enum MobileShellRoute: Hashable {
    case notebook(String)
    /// A source in the Reader, inside the notebook it was opened from, if any.
    case source(String, notebookID: String?)
    /// A notebook's page, from its Studio: the learner's own Markdown page is
    /// written in place (`MobilePageScreen`), anything else read.
    case doc(String, notebookID: String)
    /// The Space (docs/docs-design.md, "The Space"): with no place, its list
    /// of places, Pinned, Recents and spaces; with one, that place's pages.
    case space(MobileSpacePlace?)
    /// A page of the Space, which needs no notebook: a row, a link or New
    /// page opens it.
    case page(String)
    /// A saved chat, read-only.
    case savedChat(sessionID: String, title: String)
    /// The Memory screen (docs/memory-design.md, "The Memory screen on the
    /// iPhone"): today's cards over every notebook, Start Review, the history
    /// grid, and every kept card. What Home's Memory strip opens.
    case memory
    /// Today's card review (docs/memory-design.md, "The card review on the
    /// iPhone") over every notebook or one: what the Memory screen's Start
    /// Review, the widget, Siri, the reminder and `foreverlm://review` open.
    case cardReview(MemoryReviewScope)
    /// The scope's new cards that today's review leaves out — kept today, or
    /// past the day's allowance — as practice the learner started: the
    /// Memory screen's Practice N New Cards (the Mac's `startCardPractice`).
    case cardPractice(MemoryReviewScope)
    /// A notebook's Practice, from its Studio's Cards row: its kept cards,
    /// due, then new, then not yet due.
    case notebookPractice(notebookID: String)
    /// A notebook's cards to check (docs/memory-design.md, "Cards to check
    /// on the iPhone"), from its Studio's Cards row while any wait.
    case cardsToCheck(notebookID: String)
    /// A course's page, from Home's Courses (docs/notebooks-design.md,
    /// "Courses beside notebooks on screen"): a course lives in no notebook.
    case course(String)
    /// The Notebooks screen (`MobileNotebooksScreen`): every notebook, or
    /// Uncategorized's or one collection's, as Home's rail rows open it.
    case notebooks(NotebooksHomeFilter)
    case library
    case settings

    /// The stack after following `link` from `path` (the shell's `follow`).
    /// A source is pushed where the learner is, inside the notebook they are
    /// in. A notebook or a page linked from outside the app replaces the
    /// stack (Back is Home); one linked from inside it is pushed, unless it
    /// is already on the stack, which goes back to it rather than opening it
    /// twice. Today goes to Home, the review to today's card review over
    /// every notebook, over Home: recall spans every notebook by default
    /// (decisions v5, 3).
    static func following(_ link: MobileDeepLink, from path: [MobileShellRoute], fromInsideApp: Bool) -> [MobileShellRoute] {
        switch link {
        case .today:
            return []
        case .review:
            return [.cardReview(.allNotebooks)]
        case .notebook(let notebookID):
            guard fromInsideApp else { return [.notebook(notebookID)] }
            if let index = path.lastIndex(of: .notebook(notebookID)) { return Array(path[...index]) }
            return path + [.notebook(notebookID)]
        case .source(let sourceID):
            return path + [.source(sourceID, notebookID: notebookInScope(of: path))]
        case .doc(let pageID):
            guard fromInsideApp else { return [.page(pageID)] }
            if let index = path.lastIndex(where: { $0.opensPage(pageID) }) { return Array(path[...index]) }
            return path + [.page(pageID)]
        }
    }

    /// Whether this route shows the page `pageID`, from the Space or from a
    /// notebook's Studio.
    func opensPage(_ pageID: String) -> Bool {
        switch self {
        case .page(let id), .doc(let id, _): return id == pageID
        default: return false
        }
    }

    /// The stack a launch settles on: the notebook last worked in pushed over
    /// Home, unless the learner (or a link) has already gone somewhere, or
    /// there is no notebook to return to.
    static func launchPath(current: [MobileShellRoute], restoredNotebookID: String?) -> [MobileShellRoute] {
        guard current.isEmpty, let restoredNotebookID else { return current }
        return [.notebook(restoredNotebookID)]
    }

    /// The notebook the top of `path` is in: the nearest notebook, or the
    /// notebook a Reader, a Doc or a card review narrowed to it above it was
    /// opened in.
    static func notebookInScope(of path: [MobileShellRoute]) -> String? {
        for route in path.reversed() {
            switch route {
            case .notebook(let notebookID):
                return notebookID
            case .source(_, let notebookID?):
                return notebookID
            case .doc(_, let notebookID):
                return notebookID
            case .cardReview(.notebook(let notebookID)), .cardPractice(.notebook(let notebookID)), .notebookPractice(let notebookID),
                 .cardsToCheck(let notebookID):
                return notebookID
            case .source, .savedChat, .memory, .cardReview, .cardPractice, .course, .notebooks, .library, .settings, .space, .page:
                continue
            }
        }
        return nil
    }
}

// MARK: - Docs a notebook lists

/// One Artifact record as a notebook's Studio lists it: the payload's
/// `artifact` (the Mac's `ArtifactRecord` coding keys) and the body revision
/// beside it (`CloudKitArtifactPayload.bodyRevision`).
struct MobileCloudArtifact: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    /// The Mac's `ArtifactKind` raw value; nil for a Doc or a linked page.
    let kind: String?
    let homeNotebookID: String?
    let linkedNotebookIDs: [String]
    let sourceIDs: [String]
    let linkedURL: String?
    let isDraft: Bool
    let teamID: String?
    let createdAt: Date?
    let updatedAt: Date
    let bodyRevision: String?

    /// The filed rule (the Mac's `NotebookMembership.filingNotebookIDs(of:)`):
    /// a record is in every notebook its home and its links name. Citing a
    /// notebook's source earns it nothing.
    func belongs(toNotebookID notebookID: String) -> Bool {
        MobileNotebookMembership.isFiled(in: notebookID, notebookIDs: [homeNotebookID] + linkedNotebookIDs.map { Optional($0) })
    }

    /// Whether a notebook lists it at all (`NotebookOutputs.isListed`):
    /// archived and hidden records never reach this list, and a team
    /// member's private draft of a team Doc (`TeamContentIdentity
    /// .isDraftArtifactID`) opens through the team's copy, not here.
    var isListed: Bool {
        !id.hasPrefix(Self.teamDraftIDPrefix)
    }

    static let teamDraftIDPrefix = "draft_"
    static let animationKind = "animation"
    static let audioOverviewKind = "audio_overview"

    /// A Google Doc's linked page, which the Mac files under Docs.
    var isGoogleDoc: Bool {
        linkedURL.map(Self.isGoogleDocLink) ?? false
    }

    /// The Mac's `LinkedPage.kind(of:)` for a Google Doc: a document at
    /// `docs.google.com/document/…`.
    static func isGoogleDocLink(_ string: String) -> Bool {
        guard let url = URL(string: string), let host = url.host?.lowercased() else { return false }
        return host == "docs.google.com" && url.path.lowercased().hasPrefix("/document/")
    }

    /// Whether the Mac lists it under Docs (`ArtifactRecord.section`, read by
    /// `NotebookOutputs.kind(of:isAudioOverview:)`): the kind answers first —
    /// an animation is an animation and an audio overview is listed and
    /// played as one — then the link: a Markdown doc, a linked Google Doc and
    /// a link no build recognises are Docs; a Claude artifact, a Codex site or
    /// a ForeverLM site is a Site, which the phone does not list yet. A kind
    /// the Mac retired (`lesson`) decodes there as a kindless Doc, so only the
    /// two current kinds leave Docs.
    var isDoc: Bool {
        guard kind != Self.animationKind, kind != Self.audioOverviewKind else { return false }
        guard let linkedURL else { return true }
        return !Self.isSiteLink(linkedURL)
    }

    /// The Mac's `LinkedPage.kind(of:)` for the three Site families: a
    /// library-held site (`foreverlm-site://`), a Claude artifact
    /// (`claude.ai/code/artifact/<id>`, `claude.ai/public/artifacts/<id>`), a
    /// Codex site (`<name>.<…>.chatgpt.site`) and a published ForeverLM site
    /// (`sites.foreverlm.com/<slug>`). Mirrored because `LinkedPage.swift`
    /// carries Mac-only record types and is not on the iPhone's file list.
    static func isSiteLink(_ string: String) -> Bool {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        if LocalSiteServing.siteID(from: url) != nil { return true }
        guard let host = url.host?.lowercased() else { return false }
        if host == "claude.ai" || host == "www.claude.ai" {
            let parts = url.pathComponents.filter { $0 != "/" }.map { $0.lowercased() }
            guard parts.count >= 3,
                  (parts[0] == "code" && parts[1] == "artifact") || (parts[0] == "public" && parts[1] == "artifacts")
            else { return false }
            return parts[2].count >= 8 && parts[2].allSatisfy { $0.isHexDigit || $0 == "-" }
        }
        if host.hasSuffix(".chatgpt.site") {
            let labels = host.split(separator: ".")
            return labels.count >= 4 && labels.allSatisfy { !$0.isEmpty }
        }
        if host == "sites.foreverlm.com" {
            guard let slug = url.pathComponents.first(where: { $0 != "/" })?.lowercased() else { return false }
            return slug.range(of: #"^[a-z0-9](?:[a-z0-9]|-(?=[a-z0-9])){2,63}$"#, options: .regularExpression) != nil
        }
        return false
    }
}

enum MobileArtifactCatalogParser {
    /// nil for a record that is not current (archived) or cannot be read.
    static func artifact(fromPayloadData data: Data) -> MobileCloudArtifact? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let artifact = object["artifact"] as? [String: Any],
              let id = (artifact["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
              let title = artifact["title"] as? String else { return nil }
        if let archived = artifact["archivedAt"], !(archived is NSNull) { return nil }
        var seenLinks = Set<String>()
        let linked = ((artifact["linkedNotebookIDs"] as? [String]) ?? [])
            .filter { !$0.isEmpty && seenLinks.insert($0).inserted }
        var seenSources = Set<String>()
        let sources = ((artifact["sourceIDs"] as? [String]) ?? [])
            .filter { !$0.isEmpty && seenSources.insert($0).inserted }
        let linkedURL = (artifact["linkedURL"] as? String)
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let createdAt = MobileCatalogDateParser.decode(artifact["createdAt"])
        return MobileCloudArtifact(
            id: id,
            title: title,
            kind: (artifact["kind"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            homeNotebookID: (artifact["homeNotebookID"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            linkedNotebookIDs: linked,
            sourceIDs: sources,
            linkedURL: linkedURL,
            isDraft: (artifact["isDraft"] as? Bool) ?? false,
            teamID: (artifact["teamID"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            createdAt: createdAt,
            updatedAt: MobileCatalogDateParser.decode(artifact["updatedAt"]) ?? createdAt ?? .distantPast,
            bodyRevision: (object["bodyRevision"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

/// A Doc's Markdown made readable on the phone, which has no Doc editor:
/// a picture becomes "[picture: its alt text]", a link to something only
/// the Mac opens (another Doc, a chat, a quiz, a picture) keeps its words,
/// and a web link, a source's and a notebook's stay links the phone follows.
/// The sources it cites are listed under it as rows that open the Reader.
enum MobileDocMarkdown {
    struct Readable: Equatable, Sendable {
        let text: String
        let citedSourceIDs: [String]
    }

    enum Block: Equatable, Sendable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullets([String])
        case numbered([String])
        case quote(String)
        case code(String)
        case rule
    }

    /// The kinds a link may keep on the phone; any other foreverlm:// link
    /// keeps only its words.
    private static let followedKinds: Set<String> = ["source", "notebook", "project", "doc"]

    static func readable(_ markdown: String) -> Readable {
        var text = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        // Footnotes before links: a reference becomes its number first, so
        // `word[^1](aside)` is never read as a link whose words are "^1", and
        // the notes moved to the end still have their own links rewritten.
        text = footnotesAtEnd(text)
        // Pictures first, so their brackets are not read as links.
        text = replacing(#"!\[([^\]]*)\]\(([^)]*)\)"#, in: text) { groups in
            let alt = groups[0].trimmingCharacters(in: .whitespacesAndNewlines)
            return alt.isEmpty ? "[picture]" : "[picture: \(alt)]"
        }
        text = replacing(#"\[([^\]]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)"#, in: text) { groups in
            let words = groups[0]
            let target = groups[1]
            guard let url = URL(string: target), let scheme = url.scheme?.lowercased() else { return words }
            if scheme == "http" || scheme == "https" { return "[\(words)](\(target))" }
            if scheme == MobileDeepLink.productScheme, let host = url.host?.lowercased(), followedKinds.contains(host) {
                return "[\(words)](\(target))"
            }
            return words
        }
        return Readable(text: text, citedSourceIDs: ChatSourceEvidence.sourceLinkTokens(in: markdown))
    }

    /// The readable text as blocks: headings, paragraphs, lists, quotes, code
    /// and rules. Inline Markdown inside them is left for the view to render.
    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbered: [String] = []
        var quote: [String] = []
        var code: [String]?

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !bullets.isEmpty { blocks.append(.bullets(bullets)); bullets = [] }
            if !numbered.isEmpty { blocks.append(.numbered(numbered)); numbered = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }

        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if var open = code {
                if line.hasPrefix("```") {
                    blocks.append(.code(open.joined(separator: "\n")))
                    code = nil
                } else {
                    open.append(rawLine)
                    code = open
                }
                continue
            }
            if line.hasPrefix("```") {
                flush()
                code = []
                continue
            }
            if line.isEmpty {
                flush()
                continue
            }
            if let heading = heading(in: line) {
                flush()
                blocks.append(.heading(level: heading.level, text: heading.text))
                continue
            }
            if line == "---" || line == "***" || line == "___" {
                flush()
                blocks.append(.rule)
                continue
            }
            if let item = bulletItem(line) {
                if !paragraph.isEmpty || !numbered.isEmpty || !quote.isEmpty { flush() }
                bullets.append(item)
                continue
            }
            if let item = numberedItem(line) {
                if !paragraph.isEmpty || !bullets.isEmpty || !quote.isEmpty { flush() }
                numbered.append(item)
                continue
            }
            if line.hasPrefix(">") {
                if !paragraph.isEmpty || !bullets.isEmpty || !numbered.isEmpty { flush() }
                quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            if !bullets.isEmpty || !numbered.isEmpty || !quote.isEmpty { flush() }
            paragraph.append(line)
        }
        if let open = code { blocks.append(.code(open.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    private static func heading(in line: String) -> (level: Int, text: String)? {
        let markers = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(markers) else { return nil }
        let rest = line.dropFirst(markers)
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (markers, text)
    }

    private static func bulletItem(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func numberedItem(_ line: String) -> String? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return String(rest.dropFirst(2))
    }

    // MARK: Footnotes

    /// A page keeps its footnotes as GFM does, `[^label]` in the sentence and
    /// `[^label]: text` on a line of its own, and the phone shows them as
    /// Substack does: each reference becomes its note's number in superscript,
    /// and the notes leave the place they were written for a numbered list
    /// under a rule at the end, one line each, which `blocks(_:)` reads as
    /// `.rule` and `.numbered`. A note's number is its place in that list:
    /// the notes referenced, in the order of their first reference, then the
    /// ones nothing references, in the order they were written. A page with
    /// no definitions comes back exactly as it went in.
    private static func footnotesAtEnd(_ text: String) -> String {
        guard text.contains("[^") else { return text }
        let lines = text.components(separatedBy: "\n")
        var parts: [FootnotePagePart] = []
        var defined: Set<String> = []
        var body: [String] = []
        var code: [String]?
        var index = 0

        func closeBody() {
            if !body.isEmpty { parts.append(.body(body)); body = [] }
        }

        while index < lines.count {
            let line = lines[index]
            // Fences open and close as `blocks(_:)` reads them, so what the
            // phone shows as code is never searched for notes.
            let isFence = line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
            if var open = code {
                open.append(line)
                if isFence { parts.append(.code(open, closed: true)); code = nil } else { code = open }
                index += 1
                continue
            }
            if isFence {
                closeBody()
                code = [line]
                index += 1
                continue
            }
            guard let start = footnoteDefinitionStart(line) else {
                body.append(line)
                index += 1
                continue
            }
            closeBody()
            var noteLines = [start.text]
            var paragraphOpen = !start.text.isEmpty
            index += 1
            while index < lines.count {
                let next = lines[index]
                if isBlankLine(next) {
                    // A blank line ends the note unless the next written line
                    // is indented into it: a second paragraph of the note.
                    var ahead = index + 1
                    while ahead < lines.count, isBlankLine(lines[ahead]) { ahead += 1 }
                    guard ahead < lines.count, indentColumns(lines[ahead]) >= 4 else { break }
                    index = ahead
                    paragraphOpen = false
                    continue
                }
                if indentColumns(next) >= 4 {
                    noteLines.append(next)
                    paragraphOpen = true
                    index += 1
                    continue
                }
                // A lazy line carries on the note's open paragraph, unless it
                // begins a block of its own.
                guard paragraphOpen, !startsFootnoteEndingBlock(next) else { break }
                noteLines.append(next)
                index += 1
            }
            parts.append(.definition(FootnoteDefinition(key: start.key, lines: noteLines)))
            defined.insert(start.key)
        }
        if let open = code { parts.append(.code(open, closed: false)) }
        closeBody()
        guard !defined.isEmpty else { return text }

        var numbers: [String: Int] = [:]
        var referenced: [String] = []
        var noteTexts: [String: String] = [:]
        var written: [String] = []
        var pageLines: [String] = []
        var codeLeftOpen = false

        // Numbers are given in reading order, a note's own text included
        // where it was written, so a reference inside a note counts there.
        for part in parts {
            switch part {
            case .body(let lines):
                // A code span never runs across a blank line, so each run of
                // written lines is read on its own.
                var paragraph: [String] = []
                func flushParagraph() {
                    guard !paragraph.isEmpty else { return }
                    let read = superscriptingReferences(
                        in: paragraph.joined(separator: "\n"),
                        defined: defined,
                        numbers: &numbers,
                        referenced: &referenced
                    )
                    pageLines.append(read)
                    paragraph = []
                }
                for line in lines {
                    if isBlankLine(line) {
                        flushParagraph()
                        pageLines.append(line)
                    } else {
                        paragraph.append(line)
                    }
                }
                flushParagraph()
            case .code(let lines, let closed):
                pageLines.append(contentsOf: lines)
                codeLeftOpen = !closed
            case .definition(let definition):
                // The first definition of a label is its note, as GFM reads a
                // label written twice; a later one no reference can reach.
                guard noteTexts[definition.key] == nil else { continue }
                let joined = definition.lines
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                noteTexts[definition.key] = superscriptingReferences(
                    in: joined,
                    defined: defined,
                    numbers: &numbers,
                    referenced: &referenced
                )
                written.append(definition.key)
            }
        }

        let referencedSet = Set(referenced)
        let order = referenced + written.filter { !referencedSet.contains($0) }
        let notes = order.enumerated().map { offset, key -> String in
            let note = noteTexts[key] ?? ""
            // An empty note still holds its number, so the list never
            // restarts its count at the next one.
            return "\(offset + 1). \(note.isEmpty ? "—" : note)"
        }
        // A fence the page never closed is closed before the notes, which
        // would otherwise be read as its code.
        if codeLeftOpen { pageLines.append("```") }
        let page = pageLines.joined(separator: "\n")
        let pageEnd = page.lastIndex(where: { !$0.isWhitespace }).map { page.index(after: $0) } ?? page.startIndex
        let trimmedPage = String(page[..<pageEnd])
        let list = "---\n\n" + notes.joined(separator: "\n")
        return trimmedPage.isEmpty ? list : trimmedPage + "\n\n" + list
    }

    /// One footnote definition: its label as references match it, ignoring
    /// case as GFM does, and the lines of its text as written.
    private struct FootnoteDefinition {
        let key: String
        let lines: [String]
    }

    /// The page in reading order: lines that stay where they are, a fenced
    /// code block (copied untouched), or a definition that moves to the end.
    private enum FootnotePagePart {
        case body([String])
        case code([String], closed: Bool)
        case definition(FootnoteDefinition)
    }

    private static let superscriptDigits: [Character] = ["⁰", "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹"]

    /// `number` in superscript digits, as a reference shows it.
    private static func superscript(_ number: Int) -> String {
        String(String(number).compactMap { $0.wholeNumberValue.map { superscriptDigits[$0] } })
    }

    /// The label of the footnote bracket opening at `bracket`, `[^label]`,
    /// as a range of `scalars`: one or more characters that are neither
    /// whitespace nor a bracket. GFM never matches a reference whose label
    /// holds `[`, which opens a bracket of its own, and stopping there keeps
    /// every label read apart from every other, so a page is read in one pass
    /// however its brackets fall.
    private static func footnoteLabel(in scalars: [Unicode.Scalar], at bracket: Int) -> Range<Int>? {
        guard bracket + 1 < scalars.count, scalars[bracket] == "[", scalars[bracket + 1] == "^" else { return nil }
        var end = bracket + 2
        while end < scalars.count, scalars[end] != "]", scalars[end] != "[", !scalars[end].properties.isWhitespace {
            end += 1
        }
        guard end < scalars.count, end > bracket + 2, scalars[end] == "]" else { return nil }
        return (bracket + 2)..<end
    }

    /// A line that opens a footnote definition, `[^label]: text` indented at
    /// most three spaces, read as the label's key and the text after it.
    private static func footnoteDefinitionStart(_ line: String) -> (key: String, text: String)? {
        let spaces = line.prefix(while: { $0 == " " }).count
        guard spaces <= 3, line.dropFirst(spaces).hasPrefix("[^") else { return nil }
        let scalars = Array(line.unicodeScalars)
        // Spaces are one scalar each, so the bracket sits at the same offset.
        guard let label = footnoteLabel(in: scalars, at: spaces),
              label.upperBound + 1 < scalars.count,
              scalars[label.upperBound + 1] == ":" else { return nil }
        let key = String(String.UnicodeScalarView(scalars[label])).lowercased()
        let text = String(String.UnicodeScalarView(scalars[(label.upperBound + 2)...]))
            .trimmingCharacters(in: .whitespaces)
        return (key, text)
    }

    /// A line that begins a block of its own and so ends a note's lazy
    /// continuation: a heading, a list item, a quote, a fence, a rule or the
    /// next definition, as `blocks(_:)` reads them.
    private static func startsFootnoteEndingBlock(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return heading(in: trimmed) != nil
            || bulletItem(trimmed) != nil
            || numberedItem(trimmed) != nil
            || trimmed.hasPrefix(">")
            || trimmed.hasPrefix("```")
            || trimmed == "---" || trimmed == "***" || trimmed == "___"
            || footnoteDefinitionStart(line) != nil
    }

    private static func isBlankLine(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// How far a line is indented, a tab reaching the next multiple of four
    /// as Markdown counts it.
    private static func indentColumns(_ line: String) -> Int {
        var columns = 0
        for character in line {
            if character == " " { columns += 1 } else if character == "\t" { columns += 4 - columns % 4 } else { break }
        }
        return columns
    }

    /// `text` with each reference to a defined note as the note's number in
    /// superscript, a note numbered the first time it is referenced. A
    /// backslash-escaped character and a code span are kept as written, read
    /// as GFM reads them: a span opens at a run of backticks and closes at the
    /// next run of exactly as many, or the run is only backticks. One pass:
    /// each closer is looked for from the last run looked at, and a length
    /// that found none is never looked for again.
    private static func superscriptingReferences(
        in text: String,
        defined: Set<String>,
        numbers: inout [String: Int],
        referenced: inout [String]
    ) -> String {
        guard text.contains("[^") else { return text }
        let scalars = Array(text.unicodeScalars)
        var runStarts: [Int] = []
        var runLengths: [Int] = []
        var scan = 0
        while scan < scalars.count {
            guard scalars[scan] == "`" else { scan += 1; continue }
            let start = scan
            while scan < scalars.count, scalars[scan] == "`" { scan += 1 }
            runStarts.append(start)
            runLengths.append(scan - start)
        }
        var nextRun = 0
        var noCloserFrom: [Int: Int] = [:]
        func closer(from position: Int, length: Int) -> Int? {
            if let none = noCloserFrom[length], none <= position { return nil }
            while nextRun < runStarts.count, runStarts[nextRun] < position { nextRun += 1 }
            var run = nextRun
            while run < runStarts.count {
                if runLengths[run] == length { return runStarts[run] }
                run += 1
            }
            noCloserFrom[length] = position
            return nil
        }

        // Collected as scalars and made a string once: appending to a string's
        // scalar view piece by piece can copy the whole string each time.
        var output: [Unicode.Scalar] = []
        output.reserveCapacity(scalars.count)
        var copiedUpTo = 0
        var position = 0
        while position < scalars.count {
            let scalar = scalars[position]
            if scalar == "\\" {
                position += 2
                continue
            }
            if scalar == "`" {
                var end = position
                while end < scalars.count, scalars[end] == "`" { end += 1 }
                let length = end - position
                position = closer(from: end, length: length).map { $0 + length } ?? end
                continue
            }
            if scalar == "[", let label = footnoteLabel(in: scalars, at: position) {
                let key = String(String.UnicodeScalarView(scalars[label])).lowercased()
                if defined.contains(key) {
                    let number: Int
                    if let known = numbers[key] {
                        number = known
                    } else {
                        referenced.append(key)
                        number = referenced.count
                        numbers[key] = number
                    }
                    output.append(contentsOf: scalars[copiedUpTo..<position])
                    output.append(contentsOf: superscript(number).unicodeScalars)
                    position = label.upperBound + 1
                    copiedUpTo = position
                    continue
                }
            }
            position += 1
        }
        guard copiedUpTo > 0 else { return text }
        output.append(contentsOf: scalars[copiedUpTo..<scalars.count])
        return String(String.UnicodeScalarView(output))
    }

    /// Each match of `pattern` replaced by `transform` of its capture groups.
    private static func replacing(_ pattern: String, in text: String, _ transform: ([String]) -> String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = text as NSString
        var result = ""
        var cursor = 0
        for match in expression.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            result += nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let groups = (1..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : nsText.substring(with: range)
            }
            result += transform(groups)
            cursor = match.range.location + match.range.length
        }
        result += nsText.substring(from: cursor)
        return result
    }
}

// MARK: - The chats a notebook lists

/// One saved chat as a notebook's Chat tab lists it.
struct MobileNotebookChatSummary: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case text
        case voice
        case memory
    }

    let id: String
    let title: String
    let kind: Kind
    let turnCount: Int
    let startedAt: Date
    let lastActivityAt: Date
    /// The sources the chat read, by this phone's ids, its first source
    /// first: what continuing it reads again.
    var sourceIDs: [String] = []
    /// What it is, as far as continuing it on the phone goes.
    var shape: MobileNotebookChatContinuation.Shape = .chat
    /// The model its last reply ran on, as the session records it; nil when
    /// it names none.
    var modelID: String? = nil

    /// A voice session's id says so: `ios-live-`, `carplay-live-`, `mac-live-`.
    static func kind(sessionID: String, isMemoryReview: Bool) -> Kind {
        if isMemoryReview { return .memory }
        return sessionID.contains("-live-") ? .voice : .text
    }
}

// MARK: - The notebook guide

/// The Chat tab with no chat open: the notebook's guide, the Mac's
/// `NotebookChatGuide` on the phone, with the Mac's numbers and words.
enum MobileNotebookChatGuide {
    /// How many of its chats the guide lists (the Mac's
    /// `NotebookChatGuide.recentChatLimit`).
    static let recentChatLimit = 4

    /// What Suggest questions sends, as the learner's message (the Mac's
    /// `NotebookChatGuide.suggestQuestionsPrompt`).
    static let suggestQuestionsPrompt = "Suggest three questions I could ask about this notebook's sources."

    /// The latest chats under the guide, newest first as the notebook lists
    /// them.
    static func recentChats(_ chats: [MobileNotebookChatSummary]) -> [MobileNotebookChatSummary] {
        Array(chats.prefix(recentChatLimit))
    }

    /// Whether the notebook has chats the guide does not list.
    static func hasMoreChats(_ chats: [MobileNotebookChatSummary]) -> Bool {
        chats.count > recentChatLimit
    }

    /// The chats whose titles hold `query`, ignoring case and accents, in
    /// their order; all of them for an empty query (the Mac's
    /// `NotebookChatGuide.chats(_:matching:)`, its All chats search).
    static func chats(_ chats: [MobileNotebookChatSummary], matching query: String) -> [MobileNotebookChatSummary] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return chats }
        return chats.filter { $0.title.localizedStandardContains(query) }
    }
}

// MARK: - Continuing a saved chat

/// Which saved notebook chats the phone continues, what one reads then, and
/// how the turns it adds join the saved record (docs/notebooks-design.md,
/// "iPhone"). A chat keeps the sources it began with, so a continued chat
/// reads the sources the saved one read, whole, by the 240,000-character rule
/// (`MobileNotebookChatGrounding`), never the ticks. Its turns are appended to
/// the record the Mac reads, under the same session id, with every field the
/// phone does not write left as it stood.
enum MobileNotebookChatContinuation {
    /// What a saved chat is, as far as continuing it goes.
    enum Shape: Equatable, Sendable {
        /// A conversation, typed or spoken, from the phone or a Mac.
        case chat
        /// A day's memory review, graded against its cards.
        case memoryReview
        /// A review or a course quiz: the tutor asks and grades.
        case tutoredReview
        /// A chat that plays a walkthrough's cards.
        case walkthrough
    }

    /// A course quiz's sitting (the Mac's `CourseQuizSitting.sessionIDPrefix`).
    static let courseQuizSessionPrefix = "course-quiz-"

    static func shape(
        sessionID: String,
        kind: String?,
        isMemoryReview: Bool,
        hasCardIDs: Bool,
        overallScore: Double?,
        exchanges: [ReviewableChat.Exchange]
    ) -> Shape {
        if isMemoryReview || kind == ReviewSessionKind.memory.rawValue { return .memoryReview }
        if exchanges.contains(where: { WalkthroughStepTurn.marker(in: $0.question) != nil }) { return .walkthrough }
        if kind == ReviewSessionKind.review.rawValue || sessionID.hasPrefix(courseQuizSessionPrefix) {
            return .tutoredReview
        }
        // A graded turn, a score or a card queue makes a session a review
        // whatever it was called (`ReviewableChat.qualifies`), a chat
        // recorded before the kind column included.
        if hasCardIDs || overallScore != nil
            || exchanges.contains(where: { $0.score != nil || $0.ideaCoverage != nil }) {
            return .tutoredReview
        }
        return .chat
    }

    enum Verdict: Equatable, Sendable {
        case continuable
        /// Read-only; the line its screen shows in the composer's place.
        case readOnly(String)
    }

    /// Whether the phone continues a saved chat: a conversation that read
    /// sources, at least one of which this phone holds. A memory review, a
    /// review, a quiz and a walk's chat are read here and go on on the Mac.
    static func verdict(shape: Shape, sourceIDs: [String], isOnPhone: (String) -> Bool) -> Verdict {
        switch shape {
        case .memoryReview: return .readOnly("Memory reviews continue on your Mac.")
        case .tutoredReview: return .readOnly("Reviews and quizzes continue on your Mac.")
        case .walkthrough: return .readOnly("Walkthrough chats continue on your Mac.")
        case .chat: break
        }
        guard !sourceIDs.isEmpty else { return .readOnly("This chat read no sources; it continues on your Mac.") }
        guard sourceIDs.contains(where: isOnPhone) else {
            return .readOnly("This chat's sources have not reached this iPhone yet.")
        }
        return .continuable
    }

    /// The saved chat's sources this phone holds, in the chat's order, once
    /// each, and how many it names that the phone does not hold.
    static func sources<Source>(
        of sourceIDs: [String],
        lookup: (String) -> Source?
    ) -> (onPhone: [Source], missingCount: Int) {
        var seen = Set<String>()
        var onPhone: [Source] = []
        var missing = 0
        for id in sourceIDs where seen.insert(id).inserted {
            if let source = lookup(id) {
                onPhone.append(source)
            } else {
                missing += 1
            }
        }
        return (onPhone, missing)
    }

    /// A continued chat's line above its composer when it does not read every
    /// source the saved chat read; nil when it reads them all. The ticks play
    /// no part, so it never says to untick.
    static func notice(_ plan: MobileNotebookChatGrounding.Plan, missingCount: Int) -> String? {
        var parts: [String] = []
        if plan.doesNotFitCount > 0 {
            parts.append(plan.loaded.isEmpty
                ? "None of this chat's sources fits whole in a chat."
                : "Reads \(plan.loaded.count) of this chat's \(plan.tickedCount + missingCount) sources; the rest do not fit whole beside them.")
        }
        if plan.unavailableCount > 0 {
            parts.append(plan.unavailableCount == 1
                ? "1 source's text has not reached this iPhone yet."
                : "\(plan.unavailableCount) sources' text has not reached this iPhone yet.")
        }
        if missingCount > 0 {
            parts.append(missingCount == 1
                ? "1 of its sources is not on this iPhone yet."
                : "\(missingCount) of its sources are not on this iPhone yet.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// One turn a continued chat adds: the Mac's chat exchange (no tutor
    /// question, the learner's message, the reply), ungraded.
    struct AddedExchange: Equatable, Sendable {
        let id: String
        let userAnswer: String
        let evaluation: String?
        let answeredAt: Date
    }

    /// The id of the `index`th turn (from 1) one sitting adds: the same on
    /// every save of the sitting, so saving again replaces its own turns, and
    /// never one the saved chat already holds.
    static func exchangeID(sessionID: String, sitting: String, index: Int) -> String {
        "\(sessionID)::continued::\(sitting)::\(String(format: "%04d", index))"
    }

    /// Whether a saved exchange is one a continuation appended (`exchangeID`).
    static func isContinuedExchangeID(_ id: String, sessionID: String) -> Bool {
        id.hasPrefix("\(sessionID)::continued::")
    }

    /// A whole-chat snapshot about to replace the saved session
    /// (`MobileReviewSessionRecorder.record`), keeping every turn a
    /// continuation appended that the snapshot does not hold. A chat's own
    /// view model saves its transcript whole, so one still alive when the
    /// same chat is continued elsewhere — a Reader's Ask sheet down the
    /// stack, the closed chat's last save in flight — would otherwise drop
    /// the continued turns with its late save. They follow the snapshot's own
    /// in their order, renumbered past its highest sequence number when one
    /// collides, and the session's end never moves back. Only continued
    /// turns are kept: anything else the snapshot leaves out, it left out on
    /// purpose. Nil when there is nothing to keep, so the snapshot is saved
    /// as it is.
    static func keepingContinuedTurns(snapshot: [String: Any], stored: [String: Any]) -> [String: Any]? {
        guard let sessionID = snapshot["id"] as? String,
              stored["id"] as? String == sessionID else { return nil }
        let ours = snapshot["exchanges"] as? [[String: Any]] ?? []
        let ourIDs = Set(ours.compactMap { $0["id"] as? String })
        func sequence(_ exchange: [String: Any]) -> Int {
            (exchange["sequenceNumber"] as? NSNumber)?.intValue ?? 0
        }
        let kept = (stored["exchanges"] as? [[String: Any]] ?? [])
            .filter { exchange in
                guard let id = exchange["id"] as? String else { return false }
                return isContinuedExchangeID(id, sessionID: sessionID) && !ourIDs.contains(id)
            }
            .sorted { sequence($0) < sequence($1) }
        guard !kept.isEmpty else { return nil }

        var used = Set(ours.map(sequence))
        var next = used.max() ?? 0
        var exchanges = ours
        for var exchange in kept {
            if used.contains(sequence(exchange)) {
                next += 1
                exchange["sequenceNumber"] = next
            }
            used.insert(sequence(exchange))
            next = max(next, sequence(exchange))
            exchanges.append(exchange)
        }
        var payload = snapshot
        payload["exchanges"] = exchanges.sorted { sequence($0) < sequence($1) }
        payload["exchangeCount"] = exchanges.count
        if let storedEnd = (stored["endedAt"] as? NSNumber)?.doubleValue {
            let ourEnd = (snapshot["endedAt"] as? NSNumber)?.doubleValue ?? -.infinity
            payload["endedAt"] = max(ourEnd, storedEnd)
        }
        return payload
    }

    enum Refusal: LocalizedError, Equatable {
        case otherSession
        case teamTranscript
        case notAChat

        var errorDescription: String? {
            switch self {
            case .otherSession: return "The saved record belongs to another chat."
            case .teamTranscript: return "A team's shared chat is read, never continued."
            case .notAChat: return "This saved chat is a review, which continues on your Mac."
            }
        }
    }

    /// The saved session's payload (the Mac's `CloudKitReviewSessionPayload`,
    /// as JSON) with a sitting's turns appended after its own, numbered on
    /// from its highest sequence number. Everything else is the stored
    /// payload's: title, summary, kind, sources, cards, links, and every
    /// exchange with its ids, grades and ratings. The session's end moves on,
    /// never back; its model becomes the one that answered, with the effort
    /// and speed the Mac chose cleared when that model changes (the phone asks
    /// for neither).
    static func payload(
        _ stored: [String: Any],
        sessionID: String,
        appending added: [AddedExchange],
        knowledgeNote: String,
        modelProvider: String,
        modelID: String,
        endedAt: Date
    ) throws -> [String: Any] {
        guard stored["id"] as? String == sessionID else { throw Refusal.otherSession }
        if let team = stored["teamID"] as? String, !team.isEmpty { throw Refusal.teamTranscript }
        if let kind = stored["kind"] as? String,
           kind == ReviewSessionKind.memory.rawValue || kind == ReviewSessionKind.review.rawValue {
            throw Refusal.notAChat
        }

        var payload = stored
        let ownIDs = Set(added.map(\.id))
        var exchanges = (stored["exchanges"] as? [[String: Any]] ?? []).filter {
            !ownIDs.contains($0["id"] as? String ?? "")
        }
        let highest = exchanges.compactMap { ($0["sequenceNumber"] as? NSNumber)?.intValue }.max() ?? 0
        let sourceRefs = stored["sourceIDs"] as? [String] ?? []
        for (offset, exchange) in added.enumerated() {
            var row: [String: Any] = [
                "id": exchange.id,
                "sessionID": sessionID,
                "sequenceNumber": max(0, highest) + offset + 1,
                "question": "",
                "userAnswer": exchange.userAnswer,
                "sourceRefs": sourceRefs,
                "knowledgeNote": knowledgeNote,
                "answeredAt": exchange.answeredAt.timeIntervalSinceReferenceDate,
            ]
            if let evaluation = exchange.evaluation { row["evaluation"] = evaluation }
            exchanges.append(row)
        }
        payload["exchanges"] = exchanges
        payload["exchangeCount"] = exchanges.count
        payload["status"] = "completed"
        let storedEnd = (stored["endedAt"] as? NSNumber)?.doubleValue
        payload["endedAt"] = max(storedEnd ?? -.infinity, endedAt.timeIntervalSinceReferenceDate)

        let modelChanged = stored["modelProvider"] as? String != modelProvider
            || stored["modelID"] as? String != modelID
        payload["modelProvider"] = modelProvider
        payload["modelID"] = modelID
        if modelChanged {
            if stored["modelEffort"] != nil { payload["modelEffort"] = NSNull() }
            if stored["modelSpeed"] != nil { payload["modelSpeed"] = NSNull() }
        }
        return payload
    }
}

/// A saved chat's exchanges as the turns of a read-only transcript, by the
/// Mac's rule (`ReviewSessionManager.messages(from:)`): the tutor's question,
/// the learner's message, the tutor's reply, in exchange order, the voice
/// recorder's open-conversation placeholder left out, and the tutor's lines
/// read as the Mac shows them (`displayableMessageContent`): a walk's step
/// line and a memory review's source-turn line are the Mac's row chrome,
/// never prose. A reading chat older phone builds saved put the learner's
/// question where the tutor's goes and left the answer empty; such an
/// exchange of a phone chat reads as the learner asking.
enum MobileChatTranscriptTurns {
    struct Exchange: Equatable, Sendable {
        let sequenceNumber: Int
        let question: String
        let userAnswer: String?
        let evaluation: String?
    }

    struct Turn: Equatable, Sendable {
        enum Role: Equatable, Sendable { case user, assistant }
        let role: Role
        let content: String
    }

    static func turns(sessionID: String, exchanges: [Exchange]) -> [Turn] {
        let isPhoneReadingChat = sessionID.hasPrefix("ios-") && !sessionID.hasPrefix("ios-live-")
        var turns: [Turn] = []
        var lastAssistant: String?
        for exchange in exchanges.sorted(by: { $0.sequenceNumber < $1.sequenceNumber }) {
            let rawQuestion = exchange.question.trimmingCharacters(in: .whitespacesAndNewlines)
            let answer = (exchange.userAnswer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let reply = tutorLine(exchange.evaluation ?? "")
            if isPhoneReadingChat, !rawQuestion.isEmpty, answer.isEmpty, !reply.isEmpty {
                turns.append(Turn(role: .user, content: rawQuestion))
                turns.append(Turn(role: .assistant, content: reply))
                lastAssistant = reply
                continue
            }
            let question = tutorLine(rawQuestion)
            // The reply asked again as the next question is stored without
            // the lines its pages and saved cards keep; it is still the same
            // reply.
            if !question.isEmpty,
               question != RealtimeExchangeLedger.openConversationQuestion,
               modelLine(question) != lastAssistant.map(modelLine) {
                turns.append(Turn(role: .assistant, content: question))
                lastAssistant = question
            }
            if !answer.isEmpty {
                turns.append(Turn(role: .user, content: answer))
            }
            if !reply.isEmpty {
                turns.append(Turn(role: .assistant, content: reply))
                lastAssistant = reply
            }
        }
        return turns
    }

    /// A tutor line without the Mac's row chrome: a walk's step line
    /// (`WalkthroughStepTurn`) and a memory review's source turn
    /// (`MemoryReviewSourceTurn`), which the Mac draws as chips and headings.
    static func tutorLine(_ text: String) -> String {
        WalkthroughStepTurn.stripped(MemoryReviewSourceTurn.stripped(text))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A tutor line as the model reads it back in a continued chat: without
    /// the lines the Mac stores at a reply's head for the pages its steps
    /// wrote, `[Title](foreverlm://doc/<id>?card=page)` (`ChatWrittenPage`),
    /// and the cards it saved (`ChatSavedCards`), which the model never
    /// wrote. The transcript still shows them, as links. The Mac's own rule
    /// (`ReviewSessionManager.storedProse`): prose parts trimmed, joined by a
    /// blank line. A reply with neither line is returned as it was.
    static func modelLine(_ text: String) -> String {
        // Most replies hold neither.
        guard text.contains("card=page") || text.contains("://\(ChatSavedCards.host)?") else { return text }
        return ChatSavedCards.prose(of: withoutWrittenPageLines(text))
    }

    private static func withoutWrittenPageLines(_ text: String) -> String {
        var parts: [String] = []
        var pending: [Substring] = []
        func flush() {
            let prose = pending.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            pending.removeAll()
            if !prose.isEmpty { parts.append(prose) }
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if isWrittenPageLine(line) {
                flush()
            } else {
                pending.append(line)
            }
        }
        flush()
        return parts.joined(separator: "\n\n")
    }

    /// A line that is exactly `[title](foreverlm://doc/<id>?card=page)`, in
    /// the product scheme or the running build's: `ChatWrittenPage`'s
    /// grammar, which the iPhone does not compile.
    private static func isWrittenPageLine(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix(")"),
              let middle = trimmed.range(of: "](", options: .backwards) else { return false }
        let destination = trimmed[middle.upperBound..<trimmed.index(before: trimmed.endIndex)]
        guard !destination.contains(where: \.isWhitespace),
              let url = URL(string: String(destination)),
              let scheme = url.scheme?.lowercased(),
              scheme == ChatSavedCards.scheme || scheme == ForeverLMRuntimeIdentity.urlScheme.lowercased(),
              url.host?.lowercased() == "doc",
              let id = url.pathComponents.dropFirst().first?.removingPercentEncoding,
              !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .contains { $0.name == "card" && $0.value == "page" } == true
    }
}

// MARK: - The models a chat may pick

/// One model a notebook chat's model chip offers.
struct MobileChatModelChoice: Identifiable, Equatable, Hashable, Sendable {
    let preference: AIModelRoutePreference
    let name: String

    var id: String { "\(preference.provider)|\(preference.model)" }

    static func == (lhs: MobileChatModelChoice, rhs: MobileChatModelChoice) -> Bool {
        lhs.id == rhs.id && lhs.preference == rhs.preference && lhs.name == rhs.name
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// The models the learner offers in the chat picker, read from the synced
/// rows the Mac's catalog keeps (`chatModels.enabledIDs`, entries written
/// `<provider slash token>|<model id>`, and `chatModels.openRouterCustom`,
/// the directory models the learner added, which carry their names). The
/// account's default chat model leads. Nothing is offered that the learner
/// did not offer: with no row the chip holds the default alone.
enum MobileOfferedChatModels {
    static let enabledIDsKey = "chatModels.enabledIDs"
    static let customModelsKey = "chatModels.openRouterCustom"

    /// The catalog's slash tokens for the hosts a phone request can name, to
    /// the provider names a route carries (`AIProvider.rawValue` on the Mac).
    static let providerBySlashToken: [String: String] = [
        "anthropic": "Anthropic (Claude)",
        "openai": "OpenAI (GPT)",
        "gemini": "Google (Gemini)",
        "xai": "xAI (Grok)",
        "meta": "Meta (Muse Spark)",
        "openrouter": "OpenRouter",
    ]

    private struct CustomModel: Decodable {
        let id: String
        let name: String
    }

    /// The directory models' names by model id.
    static func customNames(from data: Data?) -> [String: String] {
        guard let data, let models = try? JSONDecoder().decode([CustomModel].self, from: data) else { return [:] }
        var names: [String: String] = [:]
        for model in models where !model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            names[model.id] = model.name
        }
        return names
    }

    /// The default first, then every offered model in the row's order, each
    /// once; an entry for a host the phone cannot reach is left out, and so is
    /// every model that is not free while Free mode is on.
    static func choices(
        enabledIDs: [String]?,
        customNames: [String: String],
        defaultPreference: AIModelRoutePreference?,
        freeModeOn: Bool
    ) -> [MobileChatModelChoice] {
        var result: [MobileChatModelChoice] = []
        var seen = Set<String>()
        func offer(_ preference: AIModelRoutePreference) {
            guard preference.isValid else { return }
            if freeModeOn, !(preference.provider == "OpenRouter" && AIFreeMode.isFreeModelID(preference.model)) { return }
            let choice = MobileChatModelChoice(
                preference: preference,
                name: displayName(model: preference.model, customNames: customNames)
            )
            guard seen.insert(choice.id).inserted else { return }
            result.append(choice)
        }
        if let defaultPreference { offer(defaultPreference) }
        for entry in enabledIDs ?? [] {
            let parts = entry.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let provider = providerBySlashToken[parts[0].lowercased()] else { continue }
            let model = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else { continue }
            offer(AIModelRoutePreference(provider: provider, model: model))
        }
        return result
    }

    /// A directory model's own name; otherwise the id read as words
    /// ("claude-haiku-4-5" → "Claude Haiku 4.5", "x-ai/grok-4.3" → "Grok 4.3").
    static func displayName(model: String, customNames: [String: String]) -> String {
        if let name = customNames[model] { return name }
        let base = model.split(separator: "/").last.map(String.init) ?? model
        var tokens = base.split(separator: "-").map(String.init).filter { !$0.isEmpty }
        if tokens.count >= 3,
           let last = tokens.last, last.allSatisfy(\.isNumber),
           tokens[tokens.count - 2].allSatisfy(\.isNumber) {
            let minor = tokens.removeLast()
            let major = tokens.removeLast()
            tokens.append("\(major).\(minor)")
        }
        let words = tokens.map { token -> String in
            let lower = token.lowercased()
            if ["gpt", "oss", "ai"].contains(lower) { return lower.uppercased() }
            guard let first = token.first, first.isLetter else { return token }
            return first.uppercased() + token.dropFirst()
        }
        return words.isEmpty ? model : words.joined(separator: " ")
    }
}

// MARK: - Home's search

/// Home's Library search: the lists' own lexical match first (title, author,
/// journal, year, the book or course), then, when that finds fewer than
/// `semanticThreshold`, the on-device meaning ranking after it, each source
/// once.
enum MobileHomeSearch {
    static let semanticThreshold = 5

    static func needsSemantic(lexicalCount: Int) -> Bool {
        lexicalCount < semanticThreshold
    }

    static func merged(lexical: [MobileCloudSource], semantic: [MobileCloudSource], limit: Int = 40) -> [MobileCloudSource] {
        var seen = Set<String>()
        var result: [MobileCloudSource] = []
        for source in lexical + semantic where seen.insert(source.id).inserted {
            result.append(source)
            if result.count >= limit { break }
        }
        return result
    }

    /// Notebooks matching every term of the query in their title, card line
    /// or instructions, in the order given.
    static func notebooks(_ notebooks: [MobileCloudNotebook], matching query: String) -> [MobileCloudNotebook] {
        let terms = MobileSourceListSearch.terms(in: query)
        guard !terms.isEmpty else { return notebooks }
        return notebooks.filter { notebook in
            let haystack = MobileSourceListSearch.folded(
                [notebook.title, notebook.summary, notebook.instructions].compactMap { $0 }.joined(separator: " ")
            )
            return terms.allSatisfy { haystack.contains($0) }
        }
    }
}

// MARK: - A notebook's Sources search

/// The one search at the top of a notebook's Sources, which reaches past the
/// notebook into the whole library (docs/notebooks-design.md, "iPhone"): the
/// notebook's own matches, then the library's — sources the notebook does not
/// list, found by their words and, when those find fewer than
/// `MobileHomeSearch.semanticThreshold`, by meaning after them. The Add
/// sources sheet finds library sources by the same rule. A source shows in
/// one section only, so one added to the notebook moves to its section.
enum MobileNotebookSourceSearch {
    struct Sections: Equatable {
        let inNotebook: [MobileCloudSource]
        let inLibrary: [MobileCloudSource]
    }

    /// The meaning ranking's answer, and the query it was run on.
    struct Meaning: Equatable {
        var query = ""
        var sources: [MobileCloudSource] = []
    }

    /// The library sources a list can offer to add: those every list shows
    /// (`MobileSourceListing`) that are not in `excluded`, in library order.
    static func libraryCandidates(
        _ library: [MobileCloudSource],
        excluding excluded: some Sequence<String>
    ) -> [MobileCloudSource] {
        let excluded = Set(excluded)
        return MobileSourceListing.listed(library).filter { !excluded.contains($0.id) }
    }

    /// The candidates matching `query`: the words' matches first, then the
    /// meaning ranking's when it was run on this very query, each source once.
    /// A ranked source that is no longer a candidate (added since the ranking
    /// ran) is left out.
    static func libraryMatches(
        in candidates: [MobileCloudSource],
        query: String,
        meaning: Meaning,
        groupTitle: (MobileCloudSource) -> String? = { _ in nil }
    ) -> [MobileCloudSource] {
        guard !MobileSourceListSearch.terms(in: query).isEmpty else { return [] }
        let lexical = MobileSourceListSearch.filter(candidates, query: query, groupTitle: groupTitle)
        let candidateIDs = Set(candidates.map(\.id))
        let semantic = meaning.query == query ? meaning.sources.filter { candidateIDs.contains($0.id) } : []
        return MobileHomeSearch.merged(lexical: lexical, semantic: semantic)
    }

    /// Whether the words find so few candidates that meaning should rank them.
    static func needsMeaning(
        in candidates: [MobileCloudSource],
        query: String,
        groupTitle: (MobileCloudSource) -> String? = { _ in nil }
    ) -> Bool {
        guard !MobileSourceListSearch.terms(in: query).isEmpty else { return false }
        let lexicalCount = MobileSourceListSearch.filter(candidates, query: query, groupTitle: groupTitle).count
        return MobileHomeSearch.needsSemantic(lexicalCount: lexicalCount)
    }

    /// The library sources the Sources tab's search can offer: those the
    /// notebook does not list — neither one it holds (`held`, its own) nor
    /// one a related notebook lends its chat (in `notebook`, its rows).
    static func libraryCandidates(
        _ library: [MobileCloudSource],
        notListedIn notebook: [MobileCloudSource],
        held: [String]
    ) -> [MobileCloudSource] {
        libraryCandidates(library, excluding: held + notebook.map(\.id))
    }

    /// The Sources tab under search: the notebook's rows that match, in the
    /// notebook's order — by their words, and by meaning when the meaning
    /// search found them, so a source found by meaning and then added with +
    /// moves up rather than leaving both sections — then the library's
    /// matches among `candidates`.
    static func sections(
        notebook: [MobileCloudSource],
        candidates: [MobileCloudSource],
        query: String,
        meaning: Meaning,
        groupTitle: (MobileCloudSource) -> String? = { _ in nil }
    ) -> Sections {
        let lexical = MobileSourceListSearch.filter(notebook, query: query, groupTitle: groupTitle)
        let notebookIDs = Set(notebook.map(\.id))
        let byMeaning = meaning.query == query ? meaning.sources.filter { notebookIDs.contains($0.id) } : []
        return Sections(
            inNotebook: MobileHomeSearch.merged(lexical: lexical, semantic: byMeaning),
            inLibrary: libraryMatches(in: candidates, query: query, meaning: meaning, groupTitle: groupTitle)
        )
    }
}

// MARK: - What belongs to a notebook

/// Homing's two rules on the phone, the Mac's `NotebookMembership` mirrored
/// (it reads the Mac's `ArtifactRecord` and `IdeaRecord`, which the iPhone
/// does not compile): a filed thing is in every notebook its home and links
/// name, and in a Goal's notebook when filed under the Goal; a derived thing
/// rides its source and is in every notebook holding that source itself —
/// the notebook's own approved sources, not those a related notebook lends
/// its chat.
enum MobileNotebookMembership {
    /// The filed rule: whether `notebookIDs` names the notebook, directly or
    /// through a Goal nested in it (`goalParents`, Goal id → its Notebook).
    static func isFiled(in notebookID: String, notebookIDs: [String?], goalParents: [String: String] = [:]) -> Bool {
        notebookIDs.contains { id in
            guard let id, !id.isEmpty else { return false }
            return id == notebookID || goalParents[id] == notebookID
        }
    }

    /// The derived rule: whether the notebook holds `sourceID` itself.
    static func isDerived(sourceID: String, memberSourceIDs: Set<String>) -> Bool {
        memberSourceIDs.contains(sourceID)
    }
}

/// Which memory items are a notebook's cards: the Mac's own
/// `MemoryCardScope` (compiled into the phone since its card review), over
/// the notebook's approved pool. A card is anchored on one of its sources
/// (derived), or was made with the notebook, or one of its Goals, as its goal
/// (filed). The pool is the notebook's own sources only, never those a
/// related notebook lends its chat, as the Mac's `notebookCardCounts` asks
/// it, by the ids the Mac's record names and the ids this phone holds them
/// under (`MobileNotebookSourceIdentityResolver.remap`, which remaps the
/// cards' anchors the same way). The phone holds no team notebook, so no team
/// copy needs resolving to the learner's own source.
enum MobileNotebookCards {
    static func scope(
        notebookID: String,
        memberSourceIDs: some Sequence<String>,
        goalParents: [String: String] = [:]
    ) -> MemoryCardScope {
        MemoryCardScope(notebookID: notebookID, memberSourceIDs: Array(memberSourceIDs), goalParents: goalParents)
    }

    static func belongs(
        _ item: MemoryItem,
        notebookID: String,
        memberSourceIDs: Set<String>,
        goalParents: [String: String] = [:]
    ) -> Bool {
        scope(notebookID: notebookID, memberSourceIDs: memberSourceIDs, goalParents: goalParents).contains(item)
    }
}

// MARK: - The order of a notebook's outputs

/// How a notebook's Studio orders what it made, the Mac's
/// (`NotebookOutputs.ordered`): newest first by when each was made — never
/// by when it was edited, so a Doc being written on the Mac does not jump to
/// the top on every save — the undated last, ties by title, then id, so the
/// list never shuffles between redraws.
enum MobileNotebookOutputOrder {
    struct Key: Equatable, Sendable {
        let id: String
        let title: String
        let madeAt: Date?
    }

    static func ordered<Item>(_ items: [Item], key: (Item) -> Key) -> [Item] {
        items
            .map { (item: $0, key: key($0)) }
            .sorted { comesFirst($0.key, $1.key) }
            .map(\.item)
    }

    static func comesFirst(_ lhs: Key, _ rhs: Key) -> Bool {
        switch (lhs.madeAt, rhs.madeAt) {
        case let (left?, right?) where left != right: return left > right
        case (.some, .none): return true
        case (.none, .some): return false
        default: break
        }
        let byTitle = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if byTitle != .orderedSame { return byTitle == .orderedAscending }
        return lhs.id < rhs.id
    }
}

// MARK: - A notebook's Studio: its tiles and its output rows

/// The make tiles the phone's Studio draws, in order, as the Mac's Studio
/// draws its own (`NotebookStudioTile`): a labelled chip, its glyph beside
/// its word, a chevron on a tile that picks first. Only what the phone can
/// run is a tile. Of the Mac's, that is Explainer, under the Mac's title and
/// glyph; making an audio overview, cards, a report, a deep research chat, a
/// course or a note stays on the Mac (the Cards row's Practice is the phone's
/// way into its cards). Then the phone's own, each under the glyph the Mac
/// gives its feature elsewhere: Walkthrough (the Mac's Walk Through and its
/// walkthrough outputs), Review me (the notebook chat guide's "Review me on
/// it") and Quiz (the Mac's course quizzes).
enum MobileNotebookStudioTile: String, CaseIterable, Identifiable, Sendable {
    case explainer
    case walkthrough
    case reviewMe
    case quiz

    var id: String { rawValue }

    var title: String {
        switch self {
        case .explainer: return "Explainer"
        case .walkthrough: return "Walkthrough"
        case .reviewMe: return "Review me"
        case .quiz: return "Quiz"
        }
    }

    var symbolName: String {
        switch self {
        case .explainer: return "lightbulb"
        case .walkthrough: return "figure.walk"
        case .reviewMe: return "graduationcap"
        case .quiz: return "checklist"
        }
    }

    /// Whether the tile picks a source before making: a menu.
    var isMenu: Bool { self != .reviewMe }

    var accessibilityIdentifier: String {
        switch self {
        case .explainer: return "notebook.studio.explainer"
        case .walkthrough: return "notebook.studio.walkthrough"
        case .reviewMe: return "notebook.studio.review"
        case .quiz: return "notebook.studio.quiz"
        }
    }
}

/// The glyph each output row leads with, the Mac's (`NotebookOutput.symbolName`):
/// an overview's waveform (`ArtifactKind.audioOverview`), a Doc's note, the
/// walker, the lit bulb, the Courses rail's cap, a reading's open book.
enum MobileNotebookOutputGlyph {
    static let audioOverview = "waveform"
    static let doc = "note.text"
    static let mnemonicReading = "book.pages"
    static let walkthrough = "figure.walk"
    static let explainer = "lightbulb.fill"
    static let course = "graduationcap"
}

/// An output row's second line, the Mac's (`NotebookOutputs.subtitle` and
/// `NotebookOutputRow`, mirrored because `NotebookOutputs.swift` reads the
/// Mac's `ArtifactRecord`): the kind in a word, how many sources it was made
/// from, then when it was made — "Doc · 4 sources · 3 days ago",
/// "Course · 12 sources · yesterday", "Explainer · 1 source · 2 hours ago".
/// An audio overview's length, when this phone knows it, rides before the
/// date, where the Mac's row puts its "about 12 min".
enum MobileNotebookOutputLine {
    /// The words for an audio overview, the Mac's `AudioOverviewScript.kindLabel`.
    static let audioOverviewKind = "Audio overview"

    /// "1 source", "3 sources"; nil for none, and the line then says only
    /// what it is and when.
    static func sourcesLabel(count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 source" : "\(count) sources"
    }

    /// The line before its date: "Doc · 4 sources", "Course".
    static func subtitle(kind: String, sourceCount: Int) -> String {
        [kind, sourcesLabel(count: sourceCount)].compactMap { $0 }.joined(separator: " · ")
    }

    /// The whole line. The date is the Mac's relative one ("yesterday",
    /// "3 days ago"); nil, or a date no record really carries, says nothing.
    static func line(kind: String, sourceCount: Int, length: String? = nil, madeAt: Date?) -> String {
        var parts = [subtitle(kind: kind, sourceCount: sourceCount)]
        if let length { parts.append(length) }
        if let madeAt, madeAt > .distantPast {
            parts.append(madeAt.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }
}

/// How far an audio overview has been listened and how long it runs, for its
/// Studio row: the resume point the player saves beside the narration
/// (`ArticleSpeechPlaybackPosition`), or where it is while it plays, over the
/// narration's measured length. Nothing is estimated: an unknown length shows
/// no length and no bar.
enum MobileAudioOverviewListening {
    /// The player's resume rule (`MobileAudioReviewViewModel.resumeTime`): a
    /// point this close to the end plays from the start, so it is not a
    /// partly played overview.
    static let restartWindow: TimeInterval = 5

    /// The fraction listened while the overview is partly played; nil when
    /// either value is unknown, nothing has been played, or what is left is
    /// within the restart window.
    static func listenedFraction(position: TimeInterval?, duration: TimeInterval?) -> Double? {
        guard let position, let duration,
              position.isFinite, duration.isFinite,
              duration > 0, position > 0,
              duration - position > restartWindow else { return nil }
        return position / duration
    }

    /// "12 min", "1 hr 5 min", rounded to the minute and never under one;
    /// nil when the length is not known.
    static func lengthLabel(duration: TimeInterval?) -> String? {
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        let minutes = max(1, Int((duration / 60).rounded()))
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(minutes) min" }
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }
}
