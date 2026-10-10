import Foundation

// MARK: - The notes graph between the Docs pane and its editor
//
// docs/notes-graph-design.md, "Editor and host". The editor draws block
// references, embeds, title links, the page-foot sections and the pickers; the
// Mac answers from the graph. Everything the two say to each other is here:
// the shapes the editor reads (`NotesGraphWire`), the requests it posts
// (`ArtifactNotesGraphMessage`), the calls the host makes
// (`ArtifactNotesGraphScript`), and the bridge that carries both across the
// web view (`ArtifactNotesGraphBridge`). The answers are worked out in
// `ArtifactNotesGraphHost`.

/// The notes graph as the editor reads it: camelCase keys, a block without an
/// id written as `null`, a moment as seconds since 1970. The graph's own types
/// (`DocGraphBlock` and the rest) are storage's and encode as storage likes;
/// these are the editor's, so neither side can drift the other.
enum NotesGraphWire {
    struct Block: Encodable, Equatable, Sendable {
        var docID: String
        var key: String
        var kind: String
        var blockID: String?
        var markdown: String
        var plainText: String
        var breadcrumbs: [String]
        var childrenMarkdown: String
        var line: Int
        /// The block's page, where the editor names it: the blocks of
        /// `setGraphContext` and `setBlocks`. Left out elsewhere.
        var docTitle: String?

        init(_ block: DocGraphBlock, docTitle: String? = nil) {
            docID = block.docID
            key = block.key
            kind = block.kind.rawValue
            blockID = block.blockID
            markdown = block.markdown
            plainText = block.plainText
            breadcrumbs = block.breadcrumbs
            childrenMarkdown = block.childrenMarkdown
            line = block.line
            self.docTitle = docTitle
        }

        private enum CodingKeys: String, CodingKey {
            case docID, key, kind, blockID, markdown, plainText, breadcrumbs, childrenMarkdown, line, docTitle
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(docID, forKey: .docID)
            try container.encode(key, forKey: .key)
            try container.encode(kind, forKey: .kind)
            if let blockID {
                try container.encode(blockID, forKey: .blockID)
            } else {
                try container.encodeNil(forKey: .blockID)
            }
            try container.encode(markdown, forKey: .markdown)
            try container.encode(plainText, forKey: .plainText)
            try container.encode(breadcrumbs, forKey: .breadcrumbs)
            try container.encode(childrenMarkdown, forKey: .childrenMarkdown)
            try container.encode(line, forKey: .line)
            try container.encodeIfPresent(docTitle, forKey: .docTitle)
        }
    }

    struct Group: Encodable, Equatable, Sendable {
        var kind: String
        var id: String
        var title: String
        /// Seconds since 1970.
        var updatedAt: Double
        var blocks: [Block]

        init(_ group: DocGraphReferenceGroup) {
            kind = group.kind.rawValue
            id = group.id
            title = group.title
            updatedAt = group.updatedAt.timeIntervalSince1970
            blocks = group.blocks.map { Block($0) }
        }
    }

    struct Mention: Encodable, Equatable, Sendable {
        var docID: String
        var docTitle: String
        var revision: String
        var block: Block
        var start: Int
        var end: Int

        init(_ mention: DocGraphMention) {
            docID = mention.docID
            docTitle = mention.docTitle
            revision = mention.revision
            block = Block(mention.block)
            start = mention.start
            end = mention.end
        }
    }

    struct Hit: Encodable, Equatable, Sendable {
        var docID: String
        var docTitle: String
        var revision: String
        var block: Block

        init(_ hit: DocGraphBlockHit) {
            docID = hit.docID
            docTitle = hit.docTitle
            revision = hit.revision
            block = Block(hit.block)
        }
    }

    struct TitleTarget: Encodable, Equatable, Sendable {
        var kind = "doc"
        var id: String
    }

    /// `setGraphContext`'s argument.
    struct GraphContext: Encodable, Equatable, Sendable {
        var docID: String
        var isDailyNote: Bool
        var allowsDates: Bool
        var blocks: [String: Block]
        var titles: [String: TitleTarget]
        var refCounts: [String: Int]

        /// What the editor holds while the graph is still being read: the
        /// doc it is in, which decides whether a picked block is the editor's
        /// own to mark, and nothing else yet.
        static func provisional(docID: String, isDailyNote: Bool, allowsDates: Bool) -> GraphContext {
            GraphContext(docID: docID, isDailyNote: isDailyNote, allowsDates: allowsDates, blocks: [:], titles: [:], refCounts: [:])
        }
    }

    /// `setReferences`'s argument.
    struct References: Encodable, Equatable, Sendable {
        var linked: [Group]
        var unlinked: [Mention]
    }

    /// One thing a day held, in the page foot of its daily note.
    struct Activity: Encodable, Equatable, Sendable {
        /// "read", "listened", "watched", "highlight", "chat", "doc" or "card".
        var kind: String
        var title: String
        var detail: String
        /// An in-app address the editor posts back with `openLinkRequested`.
        var href: String
    }

    /// An earlier day drawn under a daily note.
    struct Day: Encodable, Equatable, Sendable {
        var docID: String
        var dayKey: String
        var title: String
        var markdown: String
    }

    /// `setDailyContext`'s argument.
    struct DailyContext: Encodable, Equatable, Sendable {
        var dayKey: String
        var isToday: Bool
        var activity: [Activity]
        var earlier: [Day]
        var hasMore: Bool
    }

    /// `revealBlock`'s argument: the block by its id, or by its text.
    struct Reveal: Encodable, Equatable, Sendable {
        var blockID: String?
        var plainText: String?

        init(_ reveal: DocBlockReveal) {
            blockID = reveal.blockID
            plainText = reveal.plainText
        }
    }

    /// A value as the JSON literal a call into the editor takes; `null` when
    /// it cannot be written.
    static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }

    /// The same, written off the main actor: a page of linked references can
    /// be a few hundred kilobytes, and typing must never wait on it.
    static func jsonOffMain<T: Encodable & Sendable>(_ value: T) async -> String {
        await Task.detached(priority: .userInitiated) { json(value) }.value
    }
}

// MARK: - What the editor asks

/// One request the editor posts about the graph (PROTOCOL.md, "Editor → host").
/// Read from the message body the web view hands over; a request missing what
/// it needs, or naming an id that is not one, is not a request.
enum ArtifactNotesGraphMessage: Equatable {
    case blocksRequested(blockIDs: [String])
    case blockSearchRequested(requestID: String, query: String)
    case blockIDAssigned(docID: String, key: String, revision: String, plainText: String, blockID: String)
    /// A page made from the editor: a `[[Title]]` or a `/page` row. `open` says
    /// the writer should land on it once it exists (`/page`); a page made for a
    /// `[[Title]]` link stays where it is. `nested` says the page is a subpage
    /// of the page the writer is in (the slash menu's Page row only): the host
    /// writes its parent row.
    case pageCreationRequested(docID: String, title: String, dayKey: String?, open: Bool, nested: Bool)
    case openTitleRequested(title: String)
    case openBlockRequested(blockID: String)
    case openReferenceRequested(kind: String, id: String, blockID: String?, plainText: String?)
    /// nil when the mention the editor sent back could not be read.
    case linkMentionRequested(DocGraphMention?)
    case copyToPasteboardRequested(text: String)
    case makeIdeaRequested(text: String, blockID: String?)
    case dailyNoteRequested(dayKey: String)
    case dailyNotesMoreRequested(before: String)
    case blockReferencesRequested(blockID: String)
    /// An address in the page foot (or anywhere) naming a source, and maybe
    /// one of its highlights. Posted as `openLinkRequested`.
    case openSourceRequested(NotesGraphSourceLink)

    static let messageTypes: Set<String> = [
        "blocksRequested", "blockSearchRequested", "blockIDAssigned", "pageCreationRequested",
        "openTitleRequested", "openBlockRequested", "openReferenceRequested", "linkMentionRequested",
        "copyToPasteboardRequested", "makeIdeaRequested", "dailyNoteRequested", "dailyNotesMoreRequested",
        "blockReferencesRequested",
    ]

    static func parse(type: String, payload: [String: Any]) -> ArtifactNotesGraphMessage? {
        func text(_ key: String) -> String? {
            guard let value = payload[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        func blockID(_ key: String) -> String? {
            text(key).flatMap { DocGraphSyntax.isBlockID($0) ? $0 : nil }
        }
        func dayKey(_ key: String) -> String? {
            text(key).flatMap { DailyNote.date(forDayKey: $0) == nil ? nil : $0 }
        }

        switch type {
        case "blocksRequested":
            var seen = Set<String>()
            let ids = ((payload["blockIDs"] as? [Any]) ?? []).compactMap { $0 as? String }
                .filter { DocGraphSyntax.isBlockID($0) && seen.insert($0).inserted }
            return ids.isEmpty ? nil : .blocksRequested(blockIDs: ids)
        case "blockSearchRequested":
            guard let requestID = text("requestID") else { return nil }
            return .blockSearchRequested(requestID: requestID, query: (payload["query"] as? String) ?? "")
        case "blockIDAssigned":
            guard let docID = text("docID"), let key = text("key"), let id = blockID("blockID") else { return nil }
            return .blockIDAssigned(
                docID: docID,
                key: key,
                revision: (payload["revision"] as? String) ?? "",
                plainText: (payload["plainText"] as? String) ?? "",
                blockID: id
            )
        case "pageCreationRequested":
            guard let docID = text("docID") else { return nil }
            let day = dayKey("dayKey")
            let title = text("title") ?? day.flatMap { DailyNote.title(forDayKey: $0) }
            guard let title else { return nil }
            let open = payload["open"] as? Bool ?? false
            // The editor does not say `nested` yet: the Page row is the one
            // request that asks to land on the new page, and a day's link
            // never does. A `nested` the editor sends wins over that reading.
            let nested = payload["nested"] as? Bool ?? (open && day == nil)
            return .pageCreationRequested(docID: docID, title: title, dayKey: day, open: open, nested: nested)
        case "openTitleRequested":
            return text("title").map { .openTitleRequested(title: $0) }
        case "openBlockRequested":
            return blockID("blockID").map { .openBlockRequested(blockID: $0) }
        case "openReferenceRequested":
            guard let kind = text("kind"), ["doc", "dailyNote", "idea"].contains(kind), let id = text("id") else { return nil }
            return .openReferenceRequested(kind: kind, id: id, blockID: blockID("blockID"), plainText: text("plainText"))
        case "linkMentionRequested":
            guard let mention = payload["mention"] as? [String: Any],
                  JSONSerialization.isValidJSONObject(mention),
                  let data = try? JSONSerialization.data(withJSONObject: mention) else { return .linkMentionRequested(nil) }
            return .linkMentionRequested(try? JSONDecoder().decode(DocGraphMention.self, from: data))
        case "copyToPasteboardRequested":
            guard let value = payload["text"] as? String, !value.isEmpty else { return nil }
            return .copyToPasteboardRequested(text: value)
        case "makeIdeaRequested":
            guard let value = text("text") else { return nil }
            return .makeIdeaRequested(text: value, blockID: blockID("blockID"))
        case "dailyNoteRequested":
            return dayKey("dayKey").map { .dailyNoteRequested(dayKey: $0) }
        case "dailyNotesMoreRequested":
            return dayKey("before").map { .dailyNotesMoreRequested(before: $0) }
        case "blockReferencesRequested":
            return blockID("blockID").map { .blockReferencesRequested(blockID: $0) }
        default:
            return nil
        }
    }
}

/// A source named by an in-app address — `foreverlm://source/<id>` — and,
/// for a highlight in a daily note's page foot, the mark:
/// `foreverlm://source/<id>?highlight=<highlight id>`. The editor's own
/// stand-in, `https://foreverlm.invalid/source/<id>`, reads the same.
struct NotesGraphSourceLink: Equatable, Sendable {
    let sourceID: String
    var highlightID: String?

    static func href(sourceID: String, highlightID: String? = nil) -> String {
        let base = "\(StudioEntityLink.productScheme)://source/\(StudioEntityLink.encode(sourceID))"
        guard let highlightID, !highlightID.isEmpty else { return base }
        let encoded = highlightID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? highlightID
        return "\(base)?highlight=\(encoded)"
    }

    static func parse(_ href: String) -> NotesGraphSourceLink? {
        guard let components = URLComponents(string: href.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased() else { return nil }
        let path = components.percentEncodedPath.split(separator: "/").map(String.init)
        let rawID: String?
        if scheme == StudioEntityLink.productScheme || scheme == ForeverLMRuntimeIdentity.urlScheme.lowercased() {
            guard host == "source" else { return nil }
            rawID = path.first
        } else if scheme == "https", host == StudioEntityLink.editorHost {
            guard path.count >= 2, path[0].lowercased() == "source" else { return nil }
            rawID = path[1]
        } else {
            return nil
        }
        guard let id = rawID?.removingPercentEncoding?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
        let highlight = components.queryItems?.first { $0.name == "highlight" }?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return NotesGraphSourceLink(sourceID: id, highlightID: highlight?.isEmpty == false ? highlight : nil)
    }
}

// MARK: - What the host calls

enum ArtifactNotesGraphScript {
    /// A call into the editor that does nothing on a page without the
    /// function — an editor bundle older than this host — rather than
    /// throwing in the web process. Ends on a plain value so
    /// `evaluateJavaScript` never has an object to bridge back.
    static func call(_ function: String, _ arguments: [String]) -> String {
        "(function(e){if(e&&typeof e.\(function)==='function'){e.\(function)(\(arguments.joined(separator: ",")));}})(window.foreverLMArtifactEditor);true;"
    }

    /// A string as a JavaScript literal.
    static func string(_ value: String) -> String {
        NotesGraphWire.json(value)
    }
}

/// A block to show once a doc has opened in the editor — a click on a block
/// reference, a linked reference, an embed's title — kept by the Docs canvas
/// until the editor for that doc can take it. The token makes a second click
/// on the same block a second request.
struct ArtifactBlockRevealRequest: Equatable {
    let artifactID: String
    let reveal: DocBlockReveal
    let token = UUID()
}

// MARK: - The bridge

/// The page side of the bridge: the editor's coordinator, which runs a call
/// only while it is ready and still shows the doc the call is about.
@MainActor
protocol ArtifactNotesGraphPage: AnyObject {
    @discardableResult
    func runNotesGraphScript(_ script: String, forDoc docID: String) -> Bool

    /// Takes the Markdown the page holds right now as the doc's draft, rather
    /// than the last text it posted (which trails typing by a moment). Does
    /// nothing while the page is not ready or holds another doc; throws when
    /// the page cannot be asked.
    func syncMarkdown(forDoc docID: String) async throws
}

/// How an answer finds its way back to the editor that asked. An answer for a
/// doc the editor has since left is dropped.
@MainActor
struct ArtifactNotesGraphReply {
    let docID: String
    let run: @MainActor (String) -> Void

    func setBlocks(_ blocksJSON: String) {
        run(ArtifactNotesGraphScript.call("setBlocks", [blocksJSON]))
    }

    func setBlockSearchResults(requestID: String, hitsJSON: String) {
        run(ArtifactNotesGraphScript.call("setBlockSearchResults", [ArtifactNotesGraphScript.string(requestID), hitsJSON]))
    }

    func setBlockReferencesFor(blockID: String, groupsJSON: String) {
        run(ArtifactNotesGraphScript.call("setBlockReferencesFor", [ArtifactNotesGraphScript.string(blockID), groupsJSON]))
    }
}

/// What the Docs pane tells the editor about the notes graph and what the
/// editor asks of it, across the web view. The pane's host
/// (`ArtifactNotesGraphHost`) writes the latest context, references and
/// day here; the editor's coordinator attaches when it exists and takes them
/// the moment its page is ready, and again whenever one changes. A request
/// from the page comes back through `onMessage` with its reply.
///
/// One bridge per open doc: the Docs pane makes a new editor for each doc, and
/// a pooled web view re-attached to it starts from this bridge's state rather
/// than from the last doc's.
@MainActor
final class ArtifactNotesGraphBridge {
    private(set) var docID = ""
    private(set) var isDailyNote = false
    private(set) var allowsDates = true
    private(set) var contextJSON: String?
    private(set) var referencesJSON = "null"
    private(set) var dailyContextJSON = "null"
    private var pendingReveal: ArtifactBlockRevealRequest?
    private var deliveredRevealTokens: Set<UUID> = []
    private weak var page: (any ArtifactNotesGraphPage)?
    private var pageIsReady = false
    /// The pane's handler for every request the editor posts.
    var onMessage: (@MainActor (ArtifactNotesGraphMessage, ArtifactNotesGraphReply) -> Void)?

    /// The doc this bridge speaks for. A different doc starts over, and a
    /// page already showing it hears so at once.
    func open(docID: String, isDailyNote: Bool, allowsDates: Bool) {
        let opensAnotherDoc = docID != self.docID
        if opensAnotherDoc {
            contextJSON = nil
            referencesJSON = "null"
            dailyContextJSON = "null"
            if pendingReveal?.artifactID != docID { pendingReveal = nil }
        }
        self.docID = docID
        self.isDailyNote = isDailyNote
        self.allowsDates = allowsDates
        if opensAnotherDoc, pageIsReady { deliverEverything() }
    }

    func setContext(_ json: String) {
        guard json != contextJSON else { return }
        contextJSON = json
        deliver(ArtifactNotesGraphScript.call("setGraphContext", [json]))
    }

    func setReferences(_ json: String) {
        guard json != referencesJSON else { return }
        referencesJSON = json
        deliver(ArtifactNotesGraphScript.call("setReferences", [json]))
    }

    /// `force` says it again even when nothing changed: the answer to More
    /// days that found none, which the editor still waits on.
    func setDailyContext(_ json: String, force: Bool = false) {
        guard force || json != dailyContextJSON else { return }
        dailyContextJSON = json
        deliver(ArtifactNotesGraphScript.call("setDailyContext", [json]))
    }

    /// Blocks the editor did not ask for but will draw — the ones the
    /// earlier days under a daily note reference — merged into its context.
    func mergeBlocks(_ blocksJSON: String) {
        deliver(ArtifactNotesGraphScript.call("setBlocks", [blocksJSON]))
    }

    /// Show this block once the editor has the doc — which may still be
    /// loading — and at once when it already has. Each request is shown once.
    func reveal(_ request: ArtifactBlockRevealRequest) {
        guard !deliveredRevealTokens.contains(request.token) else { return }
        pendingReveal = request
        deliverPendingReveal()
    }

    // MARK: The page's side

    func attach(_ page: any ArtifactNotesGraphPage) {
        if self.page !== page { pageIsReady = false }
        self.page = page
    }

    func detach(_ page: any ArtifactNotesGraphPage) {
        guard self.page === page else { return }
        self.page = nil
        pageIsReady = false
    }

    /// The editor's page is ready and holds this doc's Markdown: everything
    /// it should know goes now. A pooled web view still holds the last doc's
    /// sections and context, so the empty ones go too, and a context the
    /// graph has not answered yet goes as a provisional one naming this doc.
    func pageBecameReady(_ page: any ArtifactNotesGraphPage) {
        guard self.page === page else { return }
        pageIsReady = true
        deliverEverything()
    }

    private func deliverEverything() {
        // Before the pane names its doc there is nothing true to say.
        guard !docID.isEmpty else { return }
        let context = contextJSON ?? NotesGraphWire.json(
            NotesGraphWire.GraphContext.provisional(docID: docID, isDailyNote: isDailyNote, allowsDates: allowsDates)
        )
        deliver(ArtifactNotesGraphScript.call("setGraphContext", [context]))
        deliver(ArtifactNotesGraphScript.call("setReferences", [referencesJSON]))
        deliver(ArtifactNotesGraphScript.call("setDailyContext", [dailyContextJSON]))
        deliverPendingReveal()
    }

    /// The page's current text becomes the pane's draft, so what the pane
    /// then saves holds what the writer has just done in the page — a link
    /// written a moment ago included. Nothing happens while no page is ready.
    func syncMarkdownFromPage() async throws {
        guard pageIsReady, let page else { return }
        try await page.syncMarkdown(forDoc: docID)
    }

    /// A request from the page, handed to the pane with the way back.
    func receive(_ message: ArtifactNotesGraphMessage) {
        let docID = docID
        let reply = ArtifactNotesGraphReply(docID: docID) { [weak self] script in
            guard let self, self.docID == docID else { return }
            self.deliver(script)
        }
        onMessage?(message, reply)
    }

    private func deliver(_ script: String) {
        guard pageIsReady, let page else { return }
        page.runNotesGraphScript(script, forDoc: docID)
    }

    private func deliverPendingReveal() {
        guard pageIsReady, let page, let request = pendingReveal, request.artifactID == docID else { return }
        let script = ArtifactNotesGraphScript.call("revealBlock", [NotesGraphWire.json(NotesGraphWire.Reveal(request.reveal))])
        guard page.runNotesGraphScript(script, forDoc: docID) else { return }
        deliveredRevealTokens.insert(request.token)
        pendingReveal = nil
    }
}

// MARK: - Pure helpers the host leans on

enum NotesGraphHostText {
    /// The block ids a doc's Markdown references or embeds, each once, in the
    /// order they first appear: what its graph context has to carry the text
    /// of. Ids inside code are listed too; the editor draws none of them, and
    /// one block too many costs nothing.
    static func referencedBlockIDs(in markdown: String) -> [String] {
        guard markdown.contains("(("),
              let regex = try? NSRegularExpression(pattern: DocGraphSyntax.blockReferencePattern) else { return [] }
        let ns = markdown as NSString
        var seen = Set<String>()
        var ids: [String] = []
        for match in regex.matches(in: markdown, range: NSRange(location: 0, length: ns.length)) where match.numberOfRanges > 1 {
            let id = ns.substring(with: match.range(at: 1))
            if seen.insert(id).inserted { ids.append(id) }
        }
        return ids
    }

    /// An Idea's title from the words Make Idea was given: one line, the
    /// first 280 characters, any block id marker taken off.
    static func ideaTitle(from text: String) -> String {
        let oneLine = text
            .components(separatedBy: .newlines)
            .map { DocGraphSyntax.removingBlockID(from: $0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(oneLine.prefix(280))
    }

    /// What the toast says after the editor put something on the pasteboard.
    static func copyConfirmation(for text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(location: 0, length: (trimmed as NSString).length)
        if let embed = try? NSRegularExpression(pattern: DocGraphSyntax.blockEmbedPattern),
           embed.firstMatch(in: trimmed, range: range) != nil {
            return "Block embed copied"
        }
        if let reference = try? NSRegularExpression(pattern: "^" + DocGraphSyntax.blockReferencePattern + "$"),
           reference.firstMatch(in: trimmed, range: range) != nil {
            return "Block reference copied"
        }
        return "Copied"
    }

    /// Whether the Markdown holds anything the graph would resolve for a
    /// reader: a block id marker, a reference or embed, a title link or a tag.
    static func mayHoldGraphMarkup(_ markdown: String) -> Bool {
        markdown.contains("((") || markdown.contains("[[") || markdown.contains("#") || markdown.contains("^")
    }

    /// The resolved Markdown when it keeps every line of the original where
    /// it was, else the original: what the Docs pane's page may draw.
    static func lineKeepingResolution(original: String, resolved: String) -> String {
        DocPagePassage.lines(resolved).count == DocPagePassage.lines(original).count ? resolved : original
    }
}

/// The rows `[[` and the Link field offer (`setLinkTargets`), worked out from
/// the library.
enum ArtifactPageLinkTargets {
    /// The docs a link in the doc `openDocID` can point at: its own library's
    /// Markdown docs and Google Docs, newest edit first, without the doc
    /// itself, an archived or hidden one, an audio overview, or a daily note —
    /// the editor offers the days itself, as "today", "yesterday" or a date.
    static func docs(
        _ artifacts: [ArtifactRecord],
        openDocID: String,
        teamID: String?,
        isAudioOverview: (ArtifactRecord) -> Bool,
        filedUnder: (ArtifactRecord) -> String
    ) -> [ArtifactPageLinkTarget] {
        artifacts
            .filter {
                $0.id != openDocID
                    && $0.section == .docs
                    && $0.teamID == teamID
                    && $0.archivedAt == nil
                    && $0.hiddenAt == nil
                    && !DailyNote.isDailyNoteID($0.id)
                    && !isAudioOverview($0)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { doc in
                ArtifactPageLinkTarget(link: .doc(doc.id), title: doc.title, detail: doc.isDraft ? "Draft" : filedUnder(doc))
            }
    }

    /// The chats an `@` mention can point at: the learner's own, newest
    /// first, without a chat hidden from the sidebar, a shared snapshot, an
    /// external link or one with no title. Bounded, because the list is
    /// searched as the writer types and a library holds hundreds.
    static func chats(_ sessions: [ReviewSessionRecord], limit: Int = 60) -> [ArtifactPageLinkTarget] {
        sessions
            .filter {
                $0.teamID == nil
                    && $0.hiddenAt == nil
                    && $0.url == nil
                    && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
            .map { ArtifactPageLinkTarget(link: .chat($0.id), title: $0.title, detail: "Chat") }
    }

    /// The Ideas a link can point at: the open ones, newest first.
    static func ideas(_ ideas: [IdeaRecord]) -> [ArtifactPageLinkTarget] {
        ideas
            .filter { $0.isOpen && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted(by: IdeaRecord.listOrder)
            .map { ArtifactPageLinkTarget(link: .idea($0.id), title: $0.title, detail: "Idea") }
    }
}

/// Stepping between daily notes.
enum DailyNoteDays {
    static func today(now: Date = Date(), calendar: Calendar = .current) -> String {
        DailyNote.dayKey(for: now, calendar: calendar)
    }

    static func isToday(_ dayKey: String, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        dayKey == today(now: now, calendar: calendar)
    }

    /// The day `days` from `dayKey` (negative is earlier); nil for a key that
    /// names no day.
    static func dayKey(_ dayKey: String, offsetBy days: Int, calendar: Calendar = .current) -> String? {
        guard DailyNote.date(forDayKey: dayKey, calendar: calendar) != nil else { return nil }
        return PlanDate.string(dayKey, offsetBy: days, calendar: calendar)
    }
}

/// The Mac's lists ask about an `ArtifactRecord`; the rule itself is shared with the iPhone
/// (`NotesGraphDocListing` in Shared/Models/DocGraph.swift).
extension NotesGraphDocListing {
    static func isListed(_ artifact: ArtifactRecord, searchQuery: String) -> Bool {
        isListed(id: artifact.id, title: artifact.title, createdAt: artifact.createdAt,
                 updatedAt: artifact.updatedAt, searchQuery: searchQuery)
    }
}

/// What a day held in the library, for the page foot of its daily note: the
/// things read, heard, watched, chatted about and written that the day's log
/// recorded (`DayActivity`, what the Activity pane and `get_day_activity`
/// read), and the passages highlighted that day, in the order the day met
/// them. Each comes with the address that opens it.
enum NotesGraphDailyActivity {
    /// How a thing's name is found now: the kind of the log, its target and
    /// the name it was logged under, which is the answer when nothing better
    /// is known.
    typealias Titles = (_ kind: DayActivityKind, _ targetID: String, _ loggedTitle: String) -> String

    static func items(
        activities: [DayActivity],
        highlights: [SourceHighlight],
        dayKey: String,
        excludingDocID: String?,
        title: Titles,
        sourceTitle: (String) -> String?,
        calendar: Calendar = .current
    ) -> [NotesGraphWire.Activity] {
        struct Row {
            let minute: Int
            let order: Int
            let item: NotesGraphWire.Activity
        }
        var rows: [Row] = []

        // One row per thing: a source's reading, listening and watching are
        // one row under the kind that took most of it.
        var groups: [String: [DayActivity]] = [:]
        var groupOrder: [String] = []
        for activity in activities.sorted(by: DayActivityGroup.byStart) {
            if activity.kind == .doc, activity.targetID == excludingDocID { continue }
            let key = "\(activity.kind.targetKind)/\(activity.targetID)"
            if groups[key] == nil { groupOrder.append(key) }
            groups[key, default: []].append(activity)
        }
        for key in groupOrder {
            guard let spans = groups[key], let first = spans.first else { continue }
            let minutes = DayActivityGroup.minutesByKind(spans)
            let total = minutes.values.reduce(0, +)
            let kind = DayActivityGroup.dominantKind(minutes) ?? first.kind
            // A source opened for a glance is not what the day held.
            if kind.targetKind == "source", total < DayPlan.activityGlanceMinutes { continue }
            let logged = spans.first { !$0.title.isEmpty }?.title ?? ""
            var name = title(kind, first.targetID, logged).trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { name = kind.displayName }
            let detail = "\(DayPlan.clockString(minute: first.startMinute)) · \(DayActivityText.durationText(max(1, total)))"
            rows.append(Row(
                minute: first.startMinute,
                order: rows.count,
                item: NotesGraphWire.Activity(kind: wireKind(kind), title: name, detail: detail, href: first.link)
            ))
        }

        for highlight in highlights.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard let minute = DayPlan.minuteOfDay(for: highlight.createdAt, on: dayKey, calendar: calendar) else { continue }
            let quote = highlight.quote
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            let words = quote.isEmpty ? "A picture" : String(quote.prefix(240)) + (quote.count > 240 ? "…" : "")
            rows.append(Row(
                minute: minute,
                order: rows.count,
                item: NotesGraphWire.Activity(
                    kind: "highlight",
                    title: words,
                    detail: sourceTitle(highlight.sourceID) ?? "",
                    href: NotesGraphSourceLink.href(sourceID: highlight.sourceID, highlightID: highlight.id)
                )
            ))
        }

        return rows
            .sorted { $0.minute != $1.minute ? $0.minute < $1.minute : $0.order < $1.order }
            .map(\.item)
    }

    static func wireKind(_ kind: DayActivityKind) -> String {
        switch kind {
        case .reading: return "read"
        case .listening: return "listened"
        case .watching: return "watched"
        case .chat: return "chat"
        case .doc: return "doc"
        }
    }
}

/// The days drawn under a daily note: the daily notes before a day that have
/// something written in them, newest first, a handful at a time.
enum NotesGraphEarlierDays {
    struct Page: Equatable {
        var days: [NotesGraphWire.Day]
        /// The day the next page starts before: the oldest note looked at,
        /// written in or not.
        var cursor: String?
        var hasMore: Bool
    }

    /// Reads daily notes before `before` (newest first) until `wanted` with
    /// writing in them are found or none are left. `notes` is storage's
    /// `dailyNotes(before:limit:)`; `markdown` reads one note's body. A note
    /// whose body cannot be read now — still downloading — is passed over.
    static func collect(
        before: String,
        wanted: Int = 7,
        maxNotesRead: Int = 60,
        notes: (String, Int) async throws -> [ArtifactRecord],
        markdown: (String) async throws -> String
    ) async throws -> Page {
        var days: [NotesGraphWire.Day] = []
        var cursor = before
        var read = 0
        while days.count < wanted, read < maxNotesRead {
            let page = try await notes(cursor, wanted)
            for (index, record) in page.enumerated() {
                read += 1
                guard let dayKey = DailyNote.dayKey(ofID: record.id), dayKey < cursor else { continue }
                cursor = dayKey
                let body = ((try? await markdown(record.id)) ?? "")
                if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    days.append(NotesGraphWire.Day(
                        docID: record.id,
                        dayKey: dayKey,
                        title: DailyNote.title(forDayKey: dayKey) ?? record.title,
                        markdown: body
                    ))
                }
                if days.count >= wanted {
                    // Stopped inside the page: what is left of it, or a full
                    // page, may hold more.
                    return Page(days: days, cursor: cursor, hasMore: index < page.count - 1 || page.count >= wanted)
                }
            }
            if page.count < wanted { return Page(days: days, cursor: cursor, hasMore: false) }
        }
        return Page(days: days, cursor: cursor, hasMore: true)
    }
}
