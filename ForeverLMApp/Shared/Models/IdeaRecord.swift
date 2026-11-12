import Foundation

/// An idea the learner jotted down (product owner, 2026-09-20: "perhaps we can also
/// have an 'Ideas' tab which is a corollary to goals. i can jot down my ideas
/// there and then link relevant research and explorations. i just need a place
/// to jot them down").
///
/// An Idea is a thought with no date and no commitment: a sentence, a note
/// when there is more to say, and the things it draws on — the sources it
/// came from, the chats and Docs that explored it, the Goal or Notebook it
/// grew into. A Goal is what an Idea becomes when the learner puts a date on
/// it; the Idea keeps a link to that Goal so the tab shows where the thought
/// went. See docs/ideas-design.md.
///
/// Not to be confused with `SourceIdea`, the memory unit extracted from a
/// source's text (docs/memory-design.md): that is what a source says, this is
/// what the learner thought.
struct IdeaRecord: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var title: String
    /// More than the one line, when the learner wrote more. nil when never
    /// written; an emptied note is stored as nil too.
    var notes: String?
    var status: IdeaStatus
    /// Everything the Idea is linked to, in the order the links were made.
    var links: [IdeaLink]
    let createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        title: String,
        notes: String? = nil,
        status: IdeaStatus = .open,
        links: [IdeaLink] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.status = status
        self.links = links
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, notes, status, links, createdAt, updatedAt
    }

    /// Tolerant of a record from a newer build: an unknown status reads as
    /// open, and a link of a kind this build does not know is dropped rather
    /// than failing the whole record.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        status = IdeaStatus(rawValue: try container.decodeIfPresent(String.self, forKey: .status) ?? "") ?? .open
        links = try container.decodeIfPresent([IdeaLink.Lenient].self, forKey: .links)?.compactMap(\.link) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encode(status.rawValue, forKey: .status)
        try container.encode(links, forKey: .links)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    var isOpen: Bool { status == .open }
    var isArchived: Bool { status == .archived }

    /// The ids linked under one kind, in link order.
    func linkedIDs(_ kind: IdeaLinkKind) -> [String] {
        links.filter { $0.kind == kind }.map(\.targetID)
    }

    /// Newest first: an Idea is jotted down in the moment, and the last one
    /// written is the one the learner is still turning over.
    static func listOrder(_ lhs: IdeaRecord, _ rhs: IdeaRecord) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id < rhs.id
    }

    /// The title an Idea is stored under: one line, trimmed, at most this long.
    static let titleLimit = 300
    static let notesLimit = 20_000

    static func normalizedTitle(_ raw: String) -> String {
        let collapsed = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(collapsed.prefix(titleLimit))
    }

    static func normalizedNotes(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(notesLimit))
    }
}

enum IdeaStatus: String, Codable, CaseIterable, Sendable {
    /// Still being turned over.
    case open
    /// Put away, kept: the way back is Unarchive.
    case archived
}

/// What an Idea can be linked to. Research is the sources it came from and
/// the Goals and Notebooks it feeds; explorations are the chats that turned it
/// over and the Docs, Sites and animations it produced. The word for each
/// kind is what the row's chip and the MCP tools say.
enum IdeaLinkKind: String, Codable, CaseIterable, Sendable {
    /// A library source: paper, article, book, video, meeting, podcast.
    case source
    /// A Doc, Site or animation (`ArtifactRecord`).
    case artifact
    /// A chat (`ReviewSessionRecord`).
    case chat
    /// A timebound Goal — usually the one the Idea became.
    case goal
    /// A Notebook whose pool the Idea draws on.
    case notebook

    var noun: String {
        switch self {
        case .source: return "source"
        case .artifact: return "page"
        case .chat: return "chat"
        case .goal: return "goal"
        case .notebook: return "notebook"
        }
    }

    var plural: String {
        switch self {
        case .source: return "sources"
        case .artifact: return "pages"
        case .chat: return "chats"
        case .goal: return "goals"
        case .notebook: return "notebooks"
        }
    }

    var symbolName: String {
        switch self {
        case .source: return "doc.text"
        case .artifact: return "note.text"
        case .chat: return "bubble.left.and.bubble.right"
        case .goal: return "target"
        case .notebook: return "tray.full"
        }
    }

    /// The order the chips read in on a row and the groups in a picker.
    static let displayOrder: [IdeaLinkKind] = [.goal, .notebook, .source, .chat, .artifact]

    /// Reads the kind a stored record may carry as 'project' (the word a
    /// notebook was once called) as `.notebook`; writes only the current word.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let kind = Self(rawValue: raw == "project" ? Self.notebook.rawValue : raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown IdeaLinkKind \(raw)"))
        }
        self = kind
    }
}

struct IdeaLink: Codable, Equatable, Hashable, Sendable {
    let kind: IdeaLinkKind
    let targetID: String
    let addedAt: Date

    init(kind: IdeaLinkKind, targetID: String, addedAt: Date = Date()) {
        self.kind = kind
        self.targetID = targetID
        self.addedAt = addedAt
    }

    /// A decode that survives a kind this build does not know: the link is
    /// nil and the rest of the record still reads.
    struct Lenient: Decodable {
        let link: IdeaLink?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let raw = try container.decode(String.self, forKey: .kind)
            guard let kind = IdeaLinkKind(rawValue: raw) else {
                link = nil
                return
            }
            link = IdeaLink(
                kind: kind,
                targetID: try container.decode(String.self, forKey: .targetID),
                addedAt: try container.decode(Date.self, forKey: .addedAt)
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, targetID, addedAt
    }
}

