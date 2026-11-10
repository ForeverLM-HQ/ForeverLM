// Review session models, moved out of Models.swift.

import Foundation

// MARK: - Review Session Links

enum ReviewSessionProvider: String, Codable {
    case claude = "Claude"
    case chatGPT = "ChatGPT"
    case gemini = "Gemini"
    case grok = "Grok"
    case edison = "Edison Scientific"
    case metaAI = "Meta AI"
    case other = "Other"

    var icon: String {
        switch self {
        case .claude: return "sparkles"
        case .chatGPT: return "bubble.left.and.bubble.right"
        case .gemini: return "sparkle"
        case .grok: return "xmark"
        case .edison: return "lightbulb"
        case .metaAI: return "infinity"
        case .other: return "link"
        }
    }

    var logoAssetName: String? {
        switch self {
        case .claude: return "ClaudeIcon"
        case .chatGPT: return "ChatGPTIcon"
        case .gemini: return "GeminiIcon"
        case .grok: return "GrokIcon"
        case .edison: return "EdisonIcon"
        case .metaAI: return "MetaIcon"
        case .other: return nil
        }
    }

    static func infer(from urlString: String) -> ReviewSessionProvider {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return .other }
        if matchesHost(host, domain: "claude.ai") { return .claude }
        if matchesHost(host, domain: "chatgpt.com") || matchesHost(host, domain: "chat.openai.com") { return .chatGPT }
        if matchesHost(host, domain: "gemini.google.com") || matchesHost(host, domain: "aistudio.google.com") { return .gemini }
        if matchesHost(host, domain: "grok.com") || matchesHost(host, domain: "x.ai") { return .grok }
        if matchesHost(host, domain: "platform.edisonscientific.com") { return .edison }
        if matchesHost(host, domain: "meta.ai") { return .metaAI }
        return .other
    }

    private static func matchesHost(_ host: String, domain: String) -> Bool {
        host == domain || host.hasSuffix(".\(domain)")
    }
}

struct ReviewSessionRecord: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var url: String?
    var createdAt: Date
    var status: String
    var sourceIDs: [String]
    /// Summary text for completed local MCP sessions. Nil for external links
    /// (external-link rows reuse the `summary` DB column to hold the URL).
    var summary: String?
    /// Overall score (0.0–1.0) for completed local MCP sessions.
    var overallScore: Double?
    /// Number of Q/A exchanges recorded for this session.
    var exchangeCount: Int
    /// Provider/model last used to produce an in-app chat response.
    var modelProvider: String?
    var modelID: String?
    /// Learning Companion / Notebook this session was started under, when known.
    var goalID: String?
    /// The team this chat was shared into as a read-only transcript snapshot;
    /// nil for the learner's own live chats.
    var teamID: String?
    /// When the learner hid this chat from the sidebar. The chat itself is
    /// unchanged — the date lives in `hidden_review_sessions` and syncs as its
    /// own private-zone record (schema 114), so every Mac signed into the
    /// account folds the same chats — and the Hidden fold under Chats is the
    /// one place it is listed again.
    var hiddenAt: Date?

    init(
        id: String,
        title: String,
        url: String? = nil,
        createdAt: Date,
        status: String,
        sourceIDs: [String],
        summary: String? = nil,
        overallScore: Double? = nil,
        exchangeCount: Int = 0,
        modelProvider: String? = nil,
        modelID: String? = nil,
        goalID: String? = nil,
        teamID: String? = nil,
        hiddenAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.createdAt = createdAt
        self.status = status
        self.sourceIDs = sourceIDs
        self.summary = summary
        self.overallScore = overallScore
        self.exchangeCount = exchangeCount
        self.modelProvider = modelProvider
        self.modelID = modelID
        self.goalID = goalID
        self.teamID = teamID
        self.hiddenAt = hiddenAt
    }

    /// A team chat is a transcript another member (or this one) shared; it is
    /// read, never continued.
    var isTeamSnapshot: Bool { teamID != nil }

    /// Hidden from the sidebar; see `hiddenAt`.
    var isHidden: Bool { hiddenAt != nil }

    var provider: ReviewSessionProvider {
        ReviewSessionProvider.infer(from: url ?? "")
    }

    var origin: ReviewSessionOrigin {
        ReviewSessionOrigin.infer(from: id)
    }

    var isExternalLink: Bool {
        guard let url else { return false }
        return url.hasPrefix("https://") || url.hasPrefix("http://")
    }

    /// True when this row represents a local review session recorded via MCP
    /// (as opposed to an external chat share link).
    var isLocalMCPSession: Bool {
        status == "active" || status == "completed"
    }

    var modelDisplayName: String? {
        Self.modelDisplayName(modelID: modelID, modelProvider: modelProvider)
    }

    /// A stored model id as a reader sees it, e.g. "Claude Opus 5"; the raw id
    /// when its provider is not one the app knows; nil for no model.
    static func modelDisplayName(modelID: String?, modelProvider: String?) -> String? {
        guard let modelID, !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        if let provider = modelProvider.flatMap(AIProvider.init(rawValue:)) {
            return AIModelDisplayName.textModelName(modelID, provider: provider)
        }
        return modelID
    }
}

/// Device surface that created a chat. Mobile sessions have always used a
/// stable ID prefix, so origin stays available across CloudKit and the web
/// client without adding a database column or rewriting existing libraries.
enum ReviewSessionOrigin: String, Codable, Equatable {
    case other
    case iPhone
    case carPlay

    static func infer(from sessionID: String) -> ReviewSessionOrigin {
        if sessionID.hasPrefix("carplay-") { return .carPlay }
        if sessionID.hasPrefix("ios-") { return .iPhone }
        return .other
    }
}

struct ReviewExchangeRecord: Identifiable, Codable, Equatable {
    let id: String
    let sessionID: String
    let sequenceNumber: Int
    let question: String
    let userAnswer: String?
    let evaluation: String?
    let score: Double?
    let sourceRefs: [String]
    let knowledgeNote: String?
    let answeredAt: Date?
    /// The reference material the learner's message was sent with — a passage
    /// quoted out of a doc or a reader, its section, and the doc it came from.
    /// Reconstituted on resume so a chat opened on a passage still knows which
    /// passage after it is reopened. nil for a message sent with no selection,
    /// and for every message recorded before v84.
    let contextContent: String?
    /// Memory review grading (v89): `[MemoryIdeaCoverage]` JSON, the
    /// question's verdict and operation, and the learner's steer. nil on
    /// every exchange that was not graded against ideas.
    let ideaCoverage: String?
    let questionVerdict: String?
    let operation: String?
    let steer: String?
    /// The learner's thumb on one of this exchange's tutor turns (v93), the
    /// reason they gave, which field it rated, and when. nil when unrated.
    let rating: ReviewTurnRating?
    let ratingReason: String?
    let ratingField: ReviewExchangeMessageField?
    let ratedAt: Date?

    init(
        id: String,
        sessionID: String,
        sequenceNumber: Int,
        question: String,
        userAnswer: String?,
        evaluation: String?,
        score: Double?,
        sourceRefs: [String],
        knowledgeNote: String?,
        answeredAt: Date?,
        contextContent: String?,
        ideaCoverage: String? = nil,
        questionVerdict: String? = nil,
        operation: String? = nil,
        steer: String? = nil,
        rating: ReviewTurnRating? = nil,
        ratingReason: String? = nil,
        ratingField: ReviewExchangeMessageField? = nil,
        ratedAt: Date? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sequenceNumber = sequenceNumber
        self.question = question
        self.userAnswer = userAnswer
        self.evaluation = evaluation
        self.score = score
        self.sourceRefs = sourceRefs
        self.knowledgeNote = knowledgeNote
        self.answeredAt = answeredAt
        self.contextContent = contextContent
        self.ideaCoverage = ideaCoverage
        self.questionVerdict = questionVerdict
        self.operation = operation
        self.steer = steer
        self.rating = rating
        self.ratingReason = ratingReason
        self.ratingField = ratingField
        self.ratedAt = ratedAt
    }
}

/// The rolling model-written summary of a chat's older turns, and the last
/// persisted message it covers.
///
/// Local-only and regenerable: it is a cache of the transcript that every
/// device can rebuild from the exchanges it already syncs, so it never travels
/// through CloudKit. The cursor names a message by `(exchange, field)` rather
/// than by position because the in-memory transcript carries harness rows
/// (tool calls, retries) that the saved one does not, so a message count means
/// something different live and after a reopen.
struct ReviewSessionHistoryDigest: Equatable, Sendable {
    let sessionID: String
    let digest: String
    /// The exchange holding the last message folded into `digest`.
    let throughExchangeID: String
    /// Which of that exchange's messages was the last one folded.
    let throughField: ReviewExchangeMessageField
    let updatedAt: Date
}

/// A chat traced back to the passage that prompted it.
///
/// Written when the first message of a doc-originated conversation is sent —
/// not when Chat is opened, which would leave a link behind for a question
/// never asked. One row per passage a session was opened on: the same chat may
/// be pointed at a second passage later, and both are true.
///
/// The anchor is revision-bound and never re-anchored, the same contract
/// `ArtifactCommentRecord` keeps. `anchorQuote` is the durable identity — the
/// words the learner asked about, still readable after the doc moves on —
/// while `anchorStart`/`anchorEnd` locate them only while `anchorRevision`
/// still matches the doc's current revision.
struct ArtifactChatLinkRecord: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let artifactID: String
    let sessionID: String
    let anchorRevision: String
    let anchorStart: Int
    let anchorEnd: Int
    let anchorQuote: String
    /// The heading the passage sat under, for a row that has to say where in a
    /// long doc the conversation started. Empty when the passage sat under none.
    let sectionTitle: String
    let createdAt: Date

    /// Whether the stored offsets still describe the doc as it is now. A doc
    /// edited since the conversation keeps the quote and loses the position.
    func locatesPassage(inRevision revision: String) -> Bool {
        !anchorRevision.isEmpty && anchorRevision == revision && anchorEnd > anchorStart
    }

    /// Whether this link's passage is what the writer has selected now.
    ///
    /// Offsets are the answer while they still describe the doc on screen: pass
    /// the revision the selection was made in, and the two ranges only have to
    /// touch. Once the doc has moved on — a later revision, or unsaved edits,
    /// signalled by an empty `revision` — the offsets say nothing, and the quote
    /// decides: a selection that contains the asked-about words, or sits inside
    /// them, is the same passage. A short selection inside a long quote is held
    /// to a minimum length so that selecting one common word does not light up
    /// every conversation that ever used it.
    func anchors(selection: Range<Int>, selectedText: String, inRevision revision: String) -> Bool {
        if locatesPassage(inRevision: revision) {
            return anchorStart < selection.upperBound && selection.lowerBound < anchorEnd
        }
        let quote = Self.collapsedWhitespace(anchorQuote)
        let selected = Self.collapsedWhitespace(selectedText)
        guard !quote.isEmpty, !selected.isEmpty else { return false }
        if selected.contains(quote) { return true }
        return selected.count >= Self.minimumSelectionInsideQuote && quote.contains(selected)
    }

    /// Short enough to keep a selected clause, long enough to drop a word.
    static let minimumSelectionInsideQuote = 12

    /// Whitespace runs and letter case both drift when a sentence is rewritten
    /// around the passage; neither makes it a different passage.
    private static func collapsedWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
}

enum ReviewExchangeMessageField: String, Codable, Equatable {
    case question
    case userAnswer
    case evaluation
}
