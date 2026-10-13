import Foundation

/// What a record *is* when its link alone would misname it. A Markdown doc
/// and every linked page carry no kind: Docs and Sites are told apart by the
/// link. An **animation** is hosted as a ForeverLM site — the same service,
/// host and sandbox — and would read as one, so its record says what it is
/// (docs/animations-design.md). The kind rides the encrypted Artifact payload
/// and `global_artifacts.kind` (schema 117); a build that does not know a
/// kind decodes it as nil and lists the record by its link.
enum ArtifactKind: String, CaseIterable, Sendable {
    /// A moving explanation of one or more sources — HTML, SVG and script, or
    /// a rendered video file — saved through `save_animation` and listed under
    /// Animations.
    case animation
    // `lesson` was a kind for one unreleased day (schema 130, 2026-09-22); its
    // records were folded into walkthroughs and archived at schema 131, and a
    // record still carrying the word decodes as a kindless Doc.

    /// A notebook's audio overview (AudioOverview.swift): one spoken script
    /// written over the notebook's sources, homed on the notebook, with the
    /// sources it was written from as its grounding and its recipe as its
    /// body. The script and its audio live on a hidden carrier source at
    /// `foreverlm://audio-overview/<id>`, deleted with the record. Its body
    /// starts with a marker, so a build that does not know the kind still
    /// reads it as an overview (`AudioOverviewScript.isOverview`).
    case audioOverview = "audio_overview"

    /// A source's private draft deck of Memory cards (`FlashcardDeck`,
    /// docs/memory-design.md "Cards to check"): one per source under the fixed
    /// id `carddeck-<sourceID>`, with no home Notebook, no Notebook links and no
    /// team even when it was drafted from a team's notebook, grounded on its
    /// source. It is the learner's own memory state, so it is never a Doc: not
    /// in Docs, the home's Docs tab, `list_docs`, search, a notebook's outputs
    /// or a team's copies (`KnowledgeStore.loadArtifacts` leaves it out). A
    /// notebook reaches its cards through its sources. A build that does not
    /// know the kind reads the record as a Doc; its id still names it a deck
    /// (`ArtifactRecord.isCardDeck`).
    case flashcards

    /// A mnemonic reading (MnemonicReading.swift, docs/memory-design.md
    /// "Mnemonic reading"): a book's chapters, or any chapter, paper or
    /// article, read as their own stored text with recall questions after
    /// the passages they test. Homed on the notebook it was made in, grounded
    /// on its sources, its body the questions only. It opens as a Doc does,
    /// and the Docs canvas shows it as the reading; it is listed in the
    /// notebooks that hold it, not above them
    /// (`StudioViewModel.isListedOnlyInItsNotebook`). Its body starts
    /// with a marker, so a build that does not know the kind reads it as a
    /// Doc listing the questions, and a record an older build saved back
    /// without the kind is still one (`ArtifactRecord.isMnemonicReading`).
    case mnemonicReading = "mnemonic_reading"

    /// The row's and the caption's word for one of these.
    var label: String {
        switch self {
        case .animation: return "Animation"
        case .audioOverview: return AudioOverviewScript.kindLabel
        case .flashcards: return "Cards to check"
        case .mnemonicReading: return MnemonicReading.kindLabel
        }
    }

    /// The glyph rows, cards and the rail use for the kind.
    var symbolName: String {
        switch self {
        case .animation: return "sparkles.tv"
        case .audioOverview: return "waveform"
        case .flashcards: return MemoryReviewSession.sidebarIcon
        case .mnemonicReading: return Self.mnemonicReadingSymbolName
        }
    }

    /// An open book with pages, on macOS 14 and iOS 17: the reading's tile,
    /// its outputs' badge and its rows.
    static let mnemonicReadingSymbolName = "book.pages"
}

/// One canonical, globally addressable Markdown document.
///
/// `homeNotebookID` is organizational only. Access is granted by the explicit
/// many-to-many Notebook links, and removing the home Notebook never removes the
/// artifact itself.
///
/// A doc with a `linkedURL` is a *linked doc*: its canonical text lives in
/// Google Docs, and the body ForeverLM holds is the plain-text export it pulls
/// from there so chat, review and search can read it. The Markdown editor,
/// image attachments and every other body write are refused for a linked doc
/// — the only writer of its body is the export refresh.
///
/// `sourceIDs` are the sources the record is *about* — its grounding. Every
/// artifact may carry them; `save_animation` is the one writer today, so an
/// animation of a paper's pathway can be found from the paper and can open
/// it. They travel in the payload and live locally in
/// `global_artifact_source_links` (schema 117).
struct ArtifactRecord: Identifiable, Codable, Equatable, Sendable {
    /// Article text travels in the versioned Artifact body CKAsset, not inside
    /// the record payload. Keep a bounded text limit for local/editor safety;
    /// images have their own allowance inside `ArtifactBodyPackage`.
    static let markdownByteLimit = ArtifactBodyPackage.maxMarkdownBytes

    let id: String
    var title: String
    var homeNotebookID: String?
    var linkedNotebookIDs: [String]
    var isDraft: Bool
    /// The canonical Google Docs edit URL of a linked doc; nil for a doc whose
    /// body is ForeverLM's own Markdown. Travels inside the artifact's encrypted
    /// JSON payload, so it is a payload key rather than a CloudKit field.
    var linkedURL: String?
    /// The team whose library this Doc belongs to; nil for My Library.
    var teamID: String?
    /// When the learner put this doc or site away. An archived record is kept
    /// whole — its body, its page, its Notebook links — and only leaves the
    /// lists, which show it again under their Archived filter; nil while it is
    /// current. Travels inside the artifact's encrypted JSON payload, so it is
    /// a payload key rather than a CloudKit field.
    var archivedAt: Date?
    /// When the learner hid this doc or site from the Docs and Sites lists.
    /// Hiding is the learner's view of the record and nothing more: the
    /// record, its team copies and its page are untouched, `updatedAt` does
    /// not move, and the date never enters the payload — it is not a coding
    /// key — so no team member sees it. It lives in `hidden_artifacts` and
    /// syncs as its own private-zone record (schema 114), so every Mac signed
    /// into the account hides the same docs. The home's Hidden filter is the
    /// one place the record is listed again; nil while it is shown.
    var hiddenAt: Date?
    /// What the record is when its link would misname it; nil for a Markdown
    /// doc and for every linked page. Travels inside the encrypted payload.
    var kind: ArtifactKind?
    /// The sources this record is about, by id; empty for a record that names
    /// none. Travels inside the encrypted payload.
    var sourceIDs: [String]
    let createdAt: Date
    var updatedAt: Date

    /// Whether this doc is a Google Doc rather than an editable Markdown body.
    var isLinked: Bool { linkedURL != nil }

    /// Whether this record is an animation (docs/animations-design.md).
    var isAnimation: Bool { kind == .animation }

    /// Whether this record is a notebook's audio overview, by its kind. A
    /// record an older build saved back without the kind is still one when
    /// its body starts with the overview's marker; ask
    /// `AudioOverviewScript.isOverview(_:markdown:)` where the body is in hand.
    var isAudioOverview: Bool { kind == .audioOverview }

    /// Whether this record is a source's private draft deck of cards to
    /// check: by its kind, or by its fixed id when an older build saved it
    /// back without the kind.
    var isCardDeck: Bool { kind == .flashcards || MemoryCard.isDraftDeckID(id) }

    /// Whether this record is a mnemonic reading, by its kind. A record an
    /// older build saved back without the kind is still one when its body
    /// starts with the reading's marker; ask `isMnemonicReading(markdown:)`
    /// where the body is in hand.
    var isMnemonicReading: Bool { kind == .mnemonicReading }

    /// Whether this record is a mnemonic reading: its kind says so, or — for
    /// a record an older build saved back without the kind — its body does.
    /// Reading it never writes the kind back.
    func isMnemonicReading(markdown: String?) -> Bool {
        if kind == .mnemonicReading { return true }
        guard kind == nil, !isLinked, let markdown else { return false }
        return MnemonicReading.isReadingMarkdown(markdown)
    }

    /// Whether the learner has put this doc or site away.
    var isArchived: Bool { archivedAt != nil }

    /// Whether the learner has hidden this doc or site from the lists.
    var isHidden: Bool { hiddenAt != nil }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case homeNotebookID
        case linkedNotebookIDs
        case isDraft
        case linkedURL
        case teamID
        case archivedAt
        case kind
        case sourceIDs
        case createdAt
        case updatedAt
    }

    init(
        id: String,
        title: String,
        homeNotebookID: String?,
        linkedNotebookIDs: [String],
        isDraft: Bool = false,
        linkedURL: String? = nil,
        teamID: String? = nil,
        archivedAt: Date? = nil,
        hiddenAt: Date? = nil,
        kind: ArtifactKind? = nil,
        sourceIDs: [String] = [],
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.homeNotebookID = homeNotebookID
        self.linkedNotebookIDs = linkedNotebookIDs
        self.isDraft = isDraft
        self.linkedURL = linkedURL
        self.teamID = teamID
        self.archivedAt = archivedAt
        self.hiddenAt = hiddenAt
        self.kind = kind
        self.sourceIDs = sourceIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        homeNotebookID = try container.decodeIfPresent(String.self, forKey: .homeNotebookID)
        // Older payloads can omit relationships without preventing the artifact
        // itself from syncing. The receiving store preserves no implicit links.
        linkedNotebookIDs = try container.decodeIfPresent([String].self, forKey: .linkedNotebookIDs) ?? []
        // Existing records predate document status and are production docs.
        isDraft = try container.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
        // Older payloads predate linked docs; a missing key is a Markdown doc.
        linkedURL = try container.decodeIfPresent(String.self, forKey: .linkedURL)
        teamID = try container.decodeIfPresent(String.self, forKey: .teamID)
        // Older payloads predate archiving; a missing key is a current record.
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
        // Hiding is local to one Mac and never travels, so a decoded record —
        // an inbound sync, a team copy — is shown; the store keeps the date.
        hiddenAt = nil
        // Older payloads predate the kind; a missing key is a record named by
        // its link. A kind this build does not know — one a later build added
        // — decodes as nil rather than refusing the whole record, so the
        // record still syncs and lists by its link.
        kind = try container.decodeIfPresent(String.self, forKey: .kind).flatMap(ArtifactKind.init(rawValue:))
        // Older payloads predate grounding; a missing key is a record about
        // no named source.
        sourceIDs = try container.decodeIfPresent([String].self, forKey: .sourceIDs) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(homeNotebookID, forKey: .homeNotebookID)
        try container.encode(linkedNotebookIDs, forKey: .linkedNotebookIDs)
        try container.encode(isDraft, forKey: .isDraft)
        try container.encodeIfPresent(linkedURL, forKey: .linkedURL)
        try container.encodeIfPresent(teamID, forKey: .teamID)
        try container.encodeIfPresent(archivedAt, forKey: .archivedAt)
        // Absent rather than null when there is nothing to say, so a record
        // with no kind and no grounding encodes exactly as it did before 117.
        try container.encodeIfPresent(kind?.rawValue, forKey: .kind)
        if !sourceIDs.isEmpty { try container.encode(sourceIDs, forKey: .sourceIDs) }
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

/// What a page is called before its first heading names it: the Pages pane's
/// New Page and a notebook Studio's Note both make one so.
enum ArtifactPlaceholderTitle {
    static let current = "Untitled Page"

    /// The titles earlier builds gave a new one, still stored on the pages
    /// they made: "Untitled Doc" from when the surface was called Docs and
    /// "Untitled Note" from when it was called Notes.
    static let retired = ["Untitled Doc", "Untitled Note"]

    /// Titles that mean "this page has not named itself yet", so a page made
    /// under an older name keeps taking its title from its first heading.
    static func isPlaceholder(_ title: String) -> Bool {
        title == current || retired.contains(title)
    }
}

struct ArtifactMarkdownSnapshot: Equatable, Sendable {
    let artifact: ArtifactRecord
    let markdown: String
    let revision: String
}

/// The library's list of pages after a page's body was saved, worked out from
/// the list in hand and the one record the save wrote, never by reading the
/// library again. A save is a pause in typing, so it comes every few seconds
/// while the learner writes, and a list read back each time redrew every view
/// that lists pages — the Space, Recents, Pinned, the link targets — under the
/// page being written (docs/codex-parity-audit.md, F2: "Typing never touches the
/// rest of the window").
enum ArtifactListOrder {
    /// How far the listed copy of a page being written may trail its saves.
    /// What a list shows of a page's date is its day, or "minutes ago"; within
    /// a minute it would show the same.
    static let listedDateTolerance: TimeInterval = 60

    /// The order the list holds (`KnowledgeStore.loadArtifacts`,
    /// `loadMyLibraryArtifacts`): the newest change first, then by title, then
    /// by id.
    static func precedes(_ lhs: ArtifactRecord, _ rhs: ArtifactRecord) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        let byTitle = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if byTitle != .orderedSame { return byTitle == .orderedAscending }
        return lhs.id < rhs.id
    }

    /// Where `saved` moves in `list`, or nil when the list can keep what it
    /// holds: the page is not listed (a list leaves out what it does not
    /// show, and a save never adds to it), or the listed copy differs only in
    /// a date less than `listedDateTolerance` older and the page keeps its
    /// place. A save is a real edit, so the page moves toward the front past
    /// every page it is now newer than; it stays among its own run, since a
    /// team library lists the member's drafts after the team's pages
    /// (`StudioViewModel.loadScopedArtifacts`).
    static func move(afterSaving saved: ArtifactRecord, in list: [ArtifactRecord]) -> (from: Int, to: Int)? {
        guard let from = list.firstIndex(where: { $0.id == saved.id }) else { return nil }
        let isDraft = TeamContentIdentity.isDraftArtifactID(saved.id)
        var to = from
        while to > 0,
              TeamContentIdentity.isDraftArtifactID(list[to - 1].id) == isDraft,
              precedes(saved, list[to - 1]) {
            to -= 1
        }
        let listed = list[from]
        var listedAtSavedDate = listed
        listedAtSavedDate.updatedAt = saved.updatedAt
        if to == from,
           listedAtSavedDate == saved,
           saved.updatedAt.timeIntervalSince(listed.updatedAt) < listedDateTolerance {
            return nil
        }
        return (from, to)
    }

    /// Puts `saved` where `move(afterSaving:in:)` said, in place.
    static func apply(_ move: (from: Int, to: Int), saving saved: ArtifactRecord, to list: inout [ArtifactRecord]) {
        list.remove(at: move.from)
        list.insert(saved, at: move.to)
    }
}

/// A Doc attached to a chat by identity rather than by copy.
///
/// The chat carries the title, the artifact id, the body revision it was
/// attached at, and the heading outline — enough for the model to know what it
/// is holding and to ask for the parts it needs. The Markdown itself stays in
/// the artifact's body asset and is read back through `read_doc`, so
/// attaching a long document costs a few lines of prompt instead of a copy
/// that goes stale the moment the writer edits it.
struct ChatDocAttachment: Identifiable, Equatable, Sendable {
    /// Headings past this are dropped. The outline exists to orient a read, not
    /// to reproduce the document.
    static let outlineHeadingLimit = 40

    let id: String
    let title: String
    let revision: String
    let outline: [String]
    /// The canonical page address when this attachment is a linked page. A
    /// ForeverLM Site needs this identity in Chat: `read_doc` is only its
    /// rendered text copy, while `read_site_file` and `save_site` operate on
    /// the site's files at this address.
    let linkedURL: String?

    init(id: String, title: String, revision: String, outline: [String], linkedURL: String? = nil) {
        self.id = id
        self.title = title
        self.revision = revision
        self.outline = outline
        self.linkedURL = linkedURL
    }

    init(snapshot: ArtifactMarkdownSnapshot) {
        self.init(
            id: snapshot.artifact.id,
            title: snapshot.artifact.title,
            revision: snapshot.revision,
            outline: Self.outline(from: snapshot.markdown),
            linkedURL: snapshot.artifact.linkedURL
        )
    }

    /// The document's own ATX headings, in order, indented by level.
    ///
    /// This reads Markdown's structural markers, not the prose: a heading is a
    /// heading because the line starts with hashes and a space, which is a fact
    /// about the syntax rather than a judgement about what the text means.
    /// Fenced code is skipped so a shell comment cannot pose as a section.
    static func outline(from markdown: String) -> [String] {
        var headings: [String] = []
        var insideFence = false
        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                insideFence.toggle()
                continue
            }
            guard !insideFence, line.hasPrefix("#") else { continue }
            let hashes = line.prefix { $0 == "#" }
            guard hashes.count <= 6 else { continue }
            let text = line.dropFirst(hashes.count)
            guard text.hasPrefix(" ") else { continue }
            let title = text.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            headings.append(String(repeating: "  ", count: hashes.count - 1) + title)
            if headings.count == outlineHeadingLimit { break }
        }
        return headings
    }
}

struct ArtifactAttachment: Identifiable, Equatable, Sendable {
    let id: String
    let token: String
    let altText: String
}

enum ArtifactError: LocalizedError, Equatable {
    case invalidTitle
    case downloading(String)
    case unavailable(String)
    case conflict(String)
    case invalidNotebook(String)
    case unsupportedAttachment
    case attachmentTooLarge
    /// A file chosen to be attached to a page is over what a page can hold.
    case fileTooLarge(maxMegabytes: Int)
    /// The doc is a Google Doc: its body is Google's, and ForeverLM only keeps
    /// the text export of it.
    case linkedDocReadOnly(String)
    /// The doc, or another doc in the library, is already the Google Doc a
    /// conversion or link would make it.
    case alreadyLinked(String)
    /// A new note would show a picture this Mac cannot draw, so nothing was
    /// saved. Carries why, as the picture lookup put it.
    case pictureUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidTitle:
            return "A note needs a title."
        case .downloading(let title):
            return "Note “\(title)” is downloading from iCloud."
        case .unavailable(let title):
            return "Note “\(title)” is unavailable on this device."
        case .conflict(let title):
            return "Note “\(title)” changed since it was opened. Reload it before saving so the newer revision is not overwritten."
        case .invalidNotebook(let notebookID):
            return "Notebook not found: \(notebookID)"
        case .unsupportedAttachment:
            return "Choose an image file."
        case .attachmentTooLarge:
            return "Choose an image smaller than 20 MB."
        case .fileTooLarge(let maxMegabytes):
            return "A page can hold a file of up to \(maxMegabytes) MB. Choose a smaller one."
        case .linkedDocReadOnly(let title):
            return "“\(title)” is a Google Doc. Edit it in Google Docs; ForeverLM keeps a read-only text copy."
        case .alreadyLinked(let title):
            return "“\(title)” is already a Google Doc."
        case .pictureUnavailable(let reason):
            return "Nothing was saved: a note keeps its own copy of each picture it shows, and one here cannot be drawn on this Mac (\(reason))."
        }
    }
}

/// An address for one of ForeverLM's own things a doc can point at — another
/// doc, a notebook, or a chat — written into Markdown as
/// `[Title](foreverlm://doc/<id>)`, `[Title](foreverlm://notebook/<id>)` or
/// `[Title](foreverlm://chat/<id>)`. A course's written quiz is
/// `foreverlm://quiz/<id>`: a chat about a lecture links the lecture's quiz
/// rather than improvising one, and the link opens the quiz's own chat
/// (docs/lecture-quiz-design.md).
///
/// The chat address is also what the sidebar's Copy Link puts on the clipboard,
/// so a chat can be handed to a person or to an assistant working through the
/// ForeverLM plugin: every MCP tool that takes a `session_id` accepts the link
/// in its place, and a chat still in progress reads as its turns so far.
///
/// The product scheme is the stored form, so a link written on one Mac reads
/// on every client and in a Dev build alike. Two other spellings name the same
/// thing and parse here too: the running build's own scheme (`foreverlm-dev`),
/// which is how a deep link from outside the app arrives, and the editor's
/// private `https://foreverlm.invalid/<kind>/<id>` stand-in, which Milkdown's
/// link mark needs because it sanitises a non-web scheme out of the DOM.
///
/// A notebook is written `notebook`. `foreverlm://project/<id>` is the address
/// it had before the word changed and is still read, because Docs and calendar
/// events written then keep it; nothing writes it any more.
enum StudioEntityLink: Equatable, Hashable, Sendable {
    case doc(String)
    case notebook(String)
    case chat(String)
    case quiz(String)
    /// One of the learner's Ideas, `foreverlm://idea/<id>`: a Doc can link
    /// one, and the Idea lists the Docs that do (docs/notes-graph-design.md).
    case idea(String)

    static let productScheme = "foreverlm"
    static let editorHost = "foreverlm.invalid"

    var id: String {
        switch self {
        case .doc(let id), .notebook(let id), .chat(let id), .quiz(let id), .idea(let id): return id
        }
    }

    /// The host of the stored address: `doc`, `notebook`, `chat`, `quiz` or `idea`.
    var kind: String {
        switch self {
        case .doc: return "doc"
        case .notebook: return "notebook"
        case .chat: return "chat"
        case .quiz: return "quiz"
        case .idea: return "idea"
        }
    }

    /// The stored Markdown target.
    var markdownDestination: String {
        "\(Self.productScheme)://\(kind)/\(Self.encode(id))"
    }

    /// The link as a person writes it: the title as the text, escaped so a
    /// bracket in a doc's name cannot close the link early.
    func markdown(title: String) -> String {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        return "[\(text.isEmpty ? kind.capitalized : text)](\(markdownDestination))"
    }

    static func parse(_ url: URL) -> StudioEntityLink? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        let kind: String
        let rawID: String?
        if scheme == productScheme || scheme == ForeverLMRuntimeIdentity.urlScheme.lowercased() {
            kind = host
            rawID = url.pathComponents.dropFirst().first
        } else if scheme == "https", host == editorHost {
            let components = url.pathComponents.filter { $0 != "/" }
            guard components.count >= 2 else { return nil }
            kind = components[0].lowercased()
            rawID = components[1]
        } else {
            return nil
        }
        guard let id = rawID?.removingPercentEncoding?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else { return nil }
        switch kind {
        case "doc": return .doc(id)
        case "notebook", "project": return .notebook(id)
        case "chat": return .chat(id)
        case "quiz": return .quiz(id)
        case "idea": return .idea(id)
        default: return nil
        }
    }

    static func parse(destination: String) -> StudioEntityLink? {
        URL(string: destination.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap(parse)
    }

    /// The id as it appears in a link's path. Also how a `DayActivity` spells
    /// the thing it links to.
    static func encode(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
    }
}

/// A page a chat's tool wrote — made, saved, edited or renamed with
/// `create_doc`, `write_doc`, `edit_doc` or `update_doc` — drawn under the
/// reply's "Worked for" line as a card that opens it (docs/chat-design.md,
/// "Pages a chat writes").
///
/// Tool rows are never stored, so the reply keeps one line per page at its
/// head, `[Title](foreverlm://doc/<id>?card=page)`, the way the cards a call
/// saved keep theirs (`ChatSavedCards`), and a reopened chat splits the line
/// back into the card. The address is an ordinary page link, so the iPhone,
/// Web Studio and MCP transcripts read the line as a link to the page; the
/// query keeps it apart from a page link the reply wrote in its own words,
/// which stays prose.
struct ChatWrittenPage: Equatable, Hashable, Sendable {
    let id: String
    /// The title the tool reported, which the line carries; the card shows
    /// the page's title as it is now when the library holds it.
    var title: String

    /// The calls whose result names the page they wrote.
    static let toolNames: Set<String> = ["create_doc", "write_doc", "edit_doc", "update_doc"]
    /// The tool name a reopened chat's card row carries: there was no step
    /// behind it, only the line.
    static let cardRowName = "chat_page_card"
    static let markerName = "card"
    static let markerValue = "page"

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    /// The page one of `toolNames` wrote, read from its result's `doc`. Nil
    /// for any other tool, a result naming no page, and a record that is not
    /// an ordinary page (a site, an animation, an audio overview) or that the
    /// call moved to the Trash or hid.
    static func parse(toolName: String, result: String) -> ChatWrittenPage? {
        guard toolNames.contains(toolName),
              let data = result.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let doc = object["doc"] as? [String: Any],
              let id = (doc["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty,
              (doc["kind"] as? String ?? "markdown") == "markdown",
              doc["is_archived"] as? Bool != true,
              doc["is_hidden"] as? Bool != true else { return nil }
        let title = (doc["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ChatWrittenPage(id: id, title: title)
    }

    /// The Docs pane's Move to Trash, as a call.
    static let deleteToolName = "delete_doc"

    /// The page a call put away, which the turn's cards then drop: a
    /// `delete_doc` that moved it to the Trash, or one of `toolNames` whose
    /// result names it moved to the Trash or hidden. A card would open a page
    /// the same turn took away. Nil for any other call or result.
    static func removedID(toolName: String, result: String) -> String? {
        guard toolName == deleteToolName || toolNames.contains(toolName),
              let data = result.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let doc = object["doc"] as? [String: Any],
              let id = (doc["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else { return nil }
        if toolName == deleteToolName { return id }
        return doc["is_archived"] as? Bool == true || doc["is_hidden"] as? Bool == true ? id : nil
    }

    /// The turn's pages with `page` added: a page written twice is one card,
    /// under the title it was last given.
    static func adding(_ page: ChatWrittenPage, to pages: [ChatWrittenPage]) -> [ChatWrittenPage] {
        var pages = pages
        if let index = pages.firstIndex(where: { $0.id == page.id }) {
            pages[index].title = page.title
        } else {
            pages.append(page)
        }
        return pages
    }

    // MARK: The stored line

    /// `foreverlm://doc/<id>?card=page`. The id is percent-encoded down to
    /// letters, digits and `-._~`, so none can end the Markdown link early.
    var destination: String {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: Self.encodable) ?? id
        return "\(StudioEntityLink.productScheme)://doc/\(encoded)?\(Self.markerName)=\(Self.markerValue)"
    }

    var markdownLine: String {
        let text = title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        return "[\(text.isEmpty ? "Page" : text)](\(destination))"
    }

    /// The reply as it is stored: a line per page first, where the cards
    /// stood in the turn, ahead of what the reply says.
    static func storing(_ reply: String, with pages: [ChatWrittenPage]) -> String {
        guard !pages.isEmpty else { return reply }
        return (pages.map(\.markdownLine) + [reply]).joined(separator: "\n\n")
    }

    // MARK: Splitting a reply

    enum Part: Equatable, Sendable {
        case text(String)
        case page(ChatWrittenPage)
    }

    /// The reply split around its page lines: a line that is nothing but a
    /// page link carrying the card's query. A page link inside a sentence, or
    /// one the reply wrote without the query, stays prose. Prose parts are
    /// trimmed and never empty.
    static func split(_ text: String) -> [Part] {
        // Runs on every stored reply a chat reopens; most hold no page line.
        guard text.contains("\(markerName)=\(markerValue)") else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [.text(trimmed)]
        }
        var parts: [Part] = []
        var pending: [Substring] = []
        func flush() {
            let prose = pending.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            pending.removeAll()
            if !prose.isEmpty { parts.append(.text(prose)) }
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let page = pageLine(line) {
                flush()
                parts.append(.page(page))
            } else {
                pending.append(line)
            }
        }
        flush()
        return parts
    }

    /// The reply's prose without its page lines: what two stored copies of
    /// one reply are compared by, when only one of them carries the pages.
    static func prose(of text: String) -> String {
        split(text).compactMap { part -> String? in
            if case .text(let prose) = part { return prose }
            return nil
        }.joined(separator: "\n\n")
    }

    /// The page a line names when it is exactly `[title](foreverlm://doc/<id>?card=page)`.
    private static func pageLine(_ line: Substring) -> ChatWrittenPage? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // The last "](" ends the text: a title's own brackets are escaped,
        // and the address holds none.
        guard trimmed.hasPrefix("["), trimmed.hasSuffix(")"),
              let middle = trimmed.range(of: "](", options: .backwards) else { return nil }
        let destination = trimmed[middle.upperBound..<trimmed.index(before: trimmed.endIndex)]
        guard !destination.contains(where: \.isWhitespace),
              let url = URL(string: String(destination)),
              case .doc(let id)? = StudioEntityLink.parse(url),
              URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .contains(where: { $0.name == markerName && $0.value == markerValue }) == true else { return nil }
        let title = trimmed[trimmed.index(after: trimmed.startIndex)..<middle.lowerBound]
            .replacingOccurrences(of: "\\[", with: "[")
            .replacingOccurrences(of: "\\]", with: "]")
            .replacingOccurrences(of: "\\\\", with: "\\")
        return ChatWrittenPage(id: id, title: title)
    }

    private static let encodable: CharacterSet = {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()
}

/// What the library says about one web reference in a doc — a line that is
/// nothing but a link, drawn by the editor as a card, or a link cited inside a
/// sentence, drawn as a card in the margin beside its paragraph. The editor
/// asks with the addresses it holds and is answered with one of these per
/// address; the JSON shape (`state`, `sourceID`, `message`, the picture's
/// `kind`, `thumbnailURL`, `iconURL`, and the margin card's `title` and
/// `detail`) is the editor's contract.
///
/// `adding` and `failed` are the host's own states around Add to Sources: the
/// card shows a wait while the import runs and offers the button again, with
/// the reason, when it did not land.
struct ArtifactReferenceStatus: Equatable, Codable, Sendable {
    enum State: String, Codable, Sendable {
        case inLibrary
        case absent
        case adding
        case failed
        /// A team Doc's card whose import did not land: the card offers to ask
        /// the team for the source instead (docs/teams-design.md, decision 14).
        case requestable
        /// A request for the source stands in the team; the card waits.
        case requested
        /// A request stands and this Mac holds the source: the card offers Share.
        case fulfillable
    }

    var state: State
    var sourceID: String?
    var message: String?
    /// The family the tile's fallback glyph and tint follow: a `StudioSourceType`
    /// raw value for a source in the library, `page` or `pdf` for a link preview.
    /// Nil until the host has resolved the card's picture, which is how the doc
    /// view tells a card still waiting for one from a card that has none.
    var kind: String?
    /// The card's picture: an `https:` address the web view fetches itself — a
    /// podcast cover, a page's `og:image` — or a `data:` image rendered from the
    /// library's own file, a paper's first page or a chapter's cover.
    var thumbnailURL: String?
    /// The site's mark, drawn small in the tile when there is no picture.
    var iconURL: String?
    /// What a margin card calls the source: the library's title for a saved
    /// source, the page's own title for one the library does not hold. Nil
    /// leaves the card standing on the words that cite it.
    var title: String?
    /// The margin card's second line, the way the sidebar row writes it —
    /// author · venue · year for a paper, the site for a page. Nil leaves the
    /// card standing on the address's domain.
    var detail: String?

    static let absent = ArtifactReferenceStatus(state: .absent)
    static let adding = ArtifactReferenceStatus(state: .adding)

    static func inLibrary(sourceID: String) -> ArtifactReferenceStatus {
        ArtifactReferenceStatus(state: .inLibrary, sourceID: sourceID)
    }

    static func failed(_ message: String) -> ArtifactReferenceStatus {
        ArtifactReferenceStatus(state: .failed, message: message)
    }

    static func requestable(_ message: String) -> ArtifactReferenceStatus {
        ArtifactReferenceStatus(state: .requestable, message: message)
    }

    /// `requestID` rides in `sourceID`, the one id the contract carries; the
    /// message names who asked.
    static func requested(_ request: ShareRequestRecord) -> ArtifactReferenceStatus {
        ArtifactReferenceStatus(state: .requested, sourceID: request.id, message: Self.requestMessage(request))
    }

    static func fulfillable(_ request: ShareRequestRecord) -> ArtifactReferenceStatus {
        ArtifactReferenceStatus(state: .fulfillable, sourceID: request.id, message: Self.requestMessage(request))
    }

    private static func requestMessage(_ request: ShareRequestRecord) -> String {
        if let name = request.requestedByDisplayName, !name.isEmpty { return "Requested by \(name)" }
        return "Requested by a teammate"
    }
}
