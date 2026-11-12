import Foundation

/// Every source with real consumption evidence, paired with its review
/// history, derived from synced records — the phone's answer to the Mac's
/// `cohortCandidates` SQL. Portable and pure, so the Mac's unit tests run it
/// against the same shapes the SQL produces and the two clients cannot drift
/// on what is due.
///
/// The Mac reads consumption off `source_activity_days` and `read_at`, review
/// history off completed sessions, and the ladder off graded contours. The
/// phone has the same three things: Schedule placements carry the activity
/// days, `ReviewSession` records carry the sessions and their graded
/// exchanges, and sources carry `readAt`.
enum MemoryReviewCandidates {

    struct SourceInput: Equatable, Sendable {
        let id: String
        let title: String
        let sourceType: String
        let dateAdded: Date
        let readAt: Date?
        /// Hidden, archived, or still-processing sources are not reviewable,
        /// the way the Mac's query keeps to active, visible rows with content.
        let isAvailable: Bool
        /// For the expected reading time; nil when unknown.
        var wordCount: Int? = nil
        /// Highlights and notes on the source.
        var annotationCount: Int = 0

        init(
            id: String,
            title: String,
            sourceType: String,
            dateAdded: Date,
            readAt: Date?,
            isAvailable: Bool,
            wordCount: Int? = nil,
            annotationCount: Int = 0
        ) {
            self.id = id
            self.title = title
            self.sourceType = sourceType
            self.dateAdded = dateAdded
            self.readAt = readAt
            self.isAvailable = isAvailable
            self.wordCount = wordCount
            self.annotationCount = annotationCount
        }
    }

    struct GradedContour: Equatable, Sendable {
        let sourceID: String
        /// nil when the question was judged ambiguous; the ladder skips it.
        let producedFraction: Double?
        let gradedAt: Date
    }

    struct SessionInput: Equatable, Sendable {
        let id: String
        let status: String
        /// When the discussion happened: the end when there is one.
        let occurredAt: Date
        /// Resolved to the phone's own source ids already.
        let sourceIDs: [String]
        let gradedContours: [GradedContour]
        /// What would make this session review material of its own — an
        /// ordinary chat the learner took part in. nil for a session the
        /// caller already knows is not one (`ReviewableChat.summary`).
        var chat: ReviewableChat.Summary? = nil
        /// When the learner last wrote in this session, for the chat evidence
        /// on its sources; nil when they never did.
        var lastLearnerTurnAt: Date? = nil
        /// The sources the chat's turns cite by in-app link, resolved to the
        /// phone's own source ids. With `sourceIDs`, what the chat was about
        /// (`ChatSourceEvidence.discussedSourceIDs`).
        var citedSourceIDs: [String] = []

        init(
            id: String,
            status: String,
            occurredAt: Date,
            sourceIDs: [String],
            gradedContours: [GradedContour],
            chat: ReviewableChat.Summary? = nil,
            lastLearnerTurnAt: Date? = nil,
            citedSourceIDs: [String] = []
        ) {
            self.id = id
            self.status = status
            self.occurredAt = occurredAt
            self.sourceIDs = sourceIDs
            self.gradedContours = gradedContours
            self.chat = chat
            self.lastLearnerTurnAt = lastLearnerTurnAt
            self.citedSourceIDs = citedSourceIDs
        }

        /// Whether this session is a discussion of its sources in the ledger's
        /// sense: an ordinary chat the learner wrote in. A memory review, a
        /// graded quiz, a scheduled task's chat, and a chat nobody took part
        /// in are not (docs/memory-design.md, "The engagement ledger").
        var isChatDiscussion: Bool {
            guard let chat, lastLearnerTurnAt != nil else { return false }
            guard status == "active" || status == "completed" else { return false }
            guard chat.kind == nil || chat.kind == ReviewSessionKind.chat.rawValue else { return false }
            guard !MemoryReviewSession.isMemorySession(id) else { return false }
            guard !chat.hasCardIDs, chat.overallScore == nil, !chat.isScheduledTaskRun else { return false }
            return chat.gradedExchanges == 0 && chat.learnerTurns > 0
        }
    }

    /// Statuses whose sessions count as a discussion, as the Mac's query has it.
    static let discussionStatuses: Set<String> = ["completed", "external_link"]

    static func candidates(
        sources: [SourceInput],
        activityDays: [String: [SourceActivityDay]],
        sessions: [SessionInput],
        now: Date,
        minimumConfidence: SourceConsumptionConfidence = CohortSelector.selectableConfidence
    ) -> [CohortCandidate] {
        var reviewCountBySource: [String: Int] = [:]
        var lastDiscussedBySource: [String: Date] = [:]
        var contoursBySource: [String: [GradedContour]] = [:]
        var contourSessionsBySource: [String: Set<String>] = [:]
        let chatDiscussedBySource = chatDiscussions(sessions: sessions, now: now)

        for session in sessions {
            if discussionStatuses.contains(session.status) {
                for sourceID in Set(session.sourceIDs) {
                    reviewCountBySource[sourceID, default: 0] += 1
                    lastDiscussedBySource[sourceID] = max(lastDiscussedBySource[sourceID] ?? .distantPast, session.occurredAt)
                }
            }
            // A memory chat stays active all day, so the session itself is not
            // a discussion yet; its graded contours are, and the ladder is
            // derived from them.
            for contour in session.gradedContours {
                contoursBySource[contour.sourceID, default: []].append(contour)
                contourSessionsBySource[contour.sourceID, default: []].insert(session.id)
            }
        }

        var result: [CohortCandidate] = []

        // Chats the learner had are material too (docs/memory-design.md,
        // "Chats as evidence"): an ordinary chat with enough said in it enters
        // the review under its own id, the way a consumed source does, and is
        // recalled the next day. Its ladder comes from the contours graded
        // against its ideas, whose ids carry the session id as their source.
        for session in sessions {
            guard let chat = session.chat,
                  ReviewableChat.qualifies(id: session.id, status: session.status, summary: chat),
                  chat.lastActivityAt <= now else { continue }
            let contours = (contoursBySource[session.id] ?? []).sorted { $0.gradedAt < $1.gradedAt }
            result.append(
                CohortCandidate(
                    sourceID: session.id,
                    title: chat.title,
                    sourceType: ReviewableChat.sourceType,
                    consumedAt: chat.lastActivityAt,
                    confidence: .complete,
                    reviewCount: contourSessionsBySource[session.id]?.count ?? 0,
                    lastDiscussedAt: contours.last?.gradedAt,
                    contourRung: contours.isEmpty
                        ? nil
                        : ForeverLMCore.memoryReviewRung(producedFractions: contours.map(\.producedFraction))
                )
            )
        }

        for source in sources where source.isAvailable {
            let days = activityDays[source.id] ?? []
            let signals = signals(for: source, days: days, chatDiscussedAt: chatDiscussedBySource[source.id])
            guard let consumedAt = SourceConsumption.consumedAt(signals, minimumConfidence: minimumConfidence),
                  consumedAt <= now else { continue }

            let contours = (contoursBySource[source.id] ?? []).sorted { $0.gradedAt < $1.gradedAt }
            let lastDiscussed = [lastDiscussedBySource[source.id], contours.last?.gradedAt].compactMap { $0 }.max()
            result.append(
                CohortCandidate(
                    sourceID: source.id,
                    title: source.title,
                    sourceType: source.sourceType,
                    consumedAt: consumedAt,
                    confidence: SourceConsumption.confidence(signals),
                    reviewCount: max(reviewCountBySource[source.id] ?? 0, contourSessionsBySource[source.id]?.count ?? 0),
                    lastDiscussedAt: lastDiscussed,
                    contourRung: contours.isEmpty
                        ? nil
                        : ForeverLMCore.memoryReviewRung(producedFractions: contours.map(\.producedFraction)),
                    engagement: engagement(signals: signals)
                )
            )
        }
        return result.sorted { $0.sourceID < $1.sourceID }
    }

    /// The consumption signals for one source, the way the Mac's SQL builds
    /// them: deepest day, time summed over days, the last chat discussion, and
    /// the annotation count.
    static func signals(
        for source: SourceInput,
        days: [SourceActivityDay],
        chatDiscussedAt: Date?
    ) -> SourceConsumptionSignals {
        let deepest = days.max { $0.effectiveFraction < $1.effectiveFraction }
        return SourceConsumptionSignals(
            readAt: source.readAt,
            readingPositionPage: nil,
            readingPositionLocator: nil,
            dateAdded: source.dateAdded,
            maxFraction: deepest?.effectiveFraction ?? 0,
            deepestActivityAt: deepest?.lastActivityAt,
            engagedSeconds: SourceActivityDay.engagedSeconds(in: days),
            expectedSeconds: SourceConsumption.expectedSeconds(wordCount: source.wordCount),
            chatDiscussedAt: chatDiscussedAt,
            annotationCount: source.annotationCount
        )
    }

    /// The engagement the candidate carries into ranking and the briefing.
    static func engagement(signals: SourceConsumptionSignals) -> CohortEngagement {
        CohortEngagement(
            engagedSeconds: signals.engagedSeconds ?? 0,
            depth: SourceActivityDay.clampFraction(signals.maxFraction),
            chatDiscussedAt: signals.chatDiscussedAt,
            annotationCount: signals.annotationCount
        )
    }

    /// The most recent time each source was discussed in an ordinary chat the
    /// learner wrote in: cited in one of its turns, or the one source the chat
    /// was opened on (`ChatSourceEvidence.discussedSourceIDs`). A source merely
    /// attached — a Notebook's whole shelf behind one broad question — is not
    /// discussed. Discussions in the future are clock skew and are ignored.
    static func chatDiscussions(sessions: [SessionInput], now: Date) -> [String: Date] {
        var result: [String: Date] = [:]
        for session in sessions where session.isChatDiscussion {
            guard let at = session.lastLearnerTurnAt, at <= now else { continue }
            for sourceID in ChatSourceEvidence.discussedSourceIDs(attached: session.sourceIDs, cited: session.citedSourceIDs) {
                result[sourceID] = max(result[sourceID] ?? .distantPast, at)
            }
        }
        return result
    }

    /// Sources with activity since `since` that are not in `excluding`: what
    /// the learner opened but is not being quizzed on, most engaged first.
    static func touched(
        sources: [SourceInput],
        activityDays: [String: [SourceActivityDay]],
        since: Date,
        now: Date,
        excluding: Set<String>
    ) -> [CohortTouchedSource] {
        var result: [CohortTouchedSource] = []
        for source in sources where source.isAvailable && !excluding.contains(source.id) {
            let recent = (activityDays[source.id] ?? []).filter { $0.lastActivityAt >= since && $0.lastActivityAt <= now }
            guard let last = recent.map(\.lastActivityAt).max() else { continue }
            result.append(
                CohortTouchedSource(
                    sourceID: source.id,
                    title: source.title,
                    sourceType: source.sourceType,
                    lastActivityAt: last,
                    engagedSeconds: SourceActivityDay.engagedSeconds(in: recent),
                    depth: recent.map(\.effectiveFraction).max() ?? 0
                )
            )
        }
        return result.sorted { lhs, rhs in
            if lhs.engagedSeconds != rhs.engagedSeconds { return lhs.engagedSeconds > rhs.engagedSeconds }
            return lhs.sourceID < rhs.sourceID
        }
    }

    /// The day's totals since `since`, over every available source with
    /// activity and every chat discussion in the window.
    static func ledger(
        sources: [SourceInput],
        activityDays: [String: [SourceActivityDay]],
        sessions: [SessionInput],
        since: Date,
        now: Date
    ) -> MemoryReviewLedger {
        let chats = chatDiscussions(sessions: sessions, now: now)
        var ledger = MemoryReviewLedger()
        for source in sources where source.isAvailable {
            let recent = (activityDays[source.id] ?? []).filter { $0.lastActivityAt >= since && $0.lastActivityAt <= now }
            let discussed = chats[source.id].map { $0 >= since } ?? false
            guard !recent.isEmpty || discussed else { continue }
            ledger.sourceCount += 1
            ledger.engagedSeconds += SourceActivityDay.engagedSeconds(in: recent)
            if discussed { ledger.chatDiscussedCount += 1 }
            if recent.contains(where: { !$0.kinds.isDisjoint(with: [.listening, .watching]) }) {
                ledger.listenedCount += 1
            }
        }
        return ledger
    }

    /// The graded contours of one session's saved exchanges, read the way the
    /// Mac's `memoryContourHistory` reads them (`MemoryLadderEvidence`): one
    /// per source, from each idea's first grade that day, so a topic's grade
    /// counts for every source it spans and a probe's re-grade counts for none.
    static func gradedContours(sessionID: String, exchanges: [MemoryGradedExchange]) -> [GradedContour] {
        MemoryLadderEvidence.outcomes(exchanges.filter { $0.sessionID == sessionID }).compactMap { outcome in
            guard let gradedAt = outcome.gradedAt else { return nil }
            return GradedContour(sourceID: outcome.sourceID, producedFraction: outcome.producedFraction, gradedAt: gradedAt)
        }
    }

    /// The graded contours of one saved exchange, read the way the Mac's
    /// `memoryContourHistory` reads them: the source is the idea id's prefix,
    /// and an ambiguous verdict contributes no fraction.
    static func gradedContour(
        ideaCoverage: String?,
        questionVerdict: String?,
        answeredAt: Date?
    ) -> GradedContour? {
        let coverage = MemoryIdeaCoverage.decode(ideaCoverage)
        guard let first = coverage.first,
              let sourceID = SourceIdea.sourceID(fromIdeaID: first.ideaID),
              let gradedAt = answeredAt else { return nil }
        let ambiguous = questionVerdict == MemoryQuestionVerdict.ambiguous.rawValue
        return GradedContour(
            sourceID: sourceID,
            producedFraction: ambiguous ? nil : MemoryIdeaCoverage.producedFraction(coverage),
            gradedAt: gradedAt
        )
    }
}

/// Which of a chat's sources the chat was actually about.
///
/// A chat carries every source it was opened with, and a Notebook chat opens
/// with the whole Notebook. One question asked across a
/// 122-source Notebook put all 122 into the next morning's memory review as
/// "discussed yesterday", each a guaranteed first pass, when only a handful
/// had ever been opened. Attachment says what the tutor could see, not what
/// was talked about. What was talked about is what the turns cite — the
/// `[Title](foreverlm://source/ID)` links the chat renders as numbered
/// citations, in the tutor's replies or the learner's own messages — and a
/// chat opened on a single source is about that source whether or not the
/// tutor linked it. The Mac's SQL and the phone's synced records both feed
/// this one rule, so the two clients cannot disagree about what counts.
enum ChatSourceEvidence {
    /// The scheme-and-path prefix every in-app source link starts with.
    static let sourceLinkMarker = "foreverlm://source/"

    /// The sources a chat discussed: every source cited in its turns, plus its
    /// attached source when it has exactly one. An attached set of two or more
    /// vouches for none of its members on its own.
    static func discussedSourceIDs(
        attached: some Sequence<String>,
        cited: some Sequence<String>
    ) -> Set<String> {
        var result = Set(cited)
        let attachedSet = Set(attached)
        if attachedSet.count == 1 {
            result.formUnion(attachedSet)
        }
        return result
    }

    /// Extract the identity tokens from structured in-app source URLs, in
    /// order of first appearance and without repeats. Deterministic on purpose:
    /// a model may describe a source, but it never decides whether a persisted
    /// source identity exists. The token ends where a query or fragment
    /// begins, so a timed citation's `?t=754` is an anchor on the link, not
    /// part of the identity.
    static func sourceLinkTokens(in text: String) -> [String] {
        let pattern = #"foreverlm://source/([^\s)<>'\"?#]+)"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else { return [] }

        let fullRange = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        var tokens: [String] = []
        for match in expression.matches(in: text, range: fullRange) {
            guard match.numberOfRanges == 2,
                  let tokenRange = Range(match.range(at: 1), in: text) else { continue }
            let encoded = String(trimmingTrailingLinkPunctuation(text[tokenRange]))
            let token = (encoded.removingPercentEncoding ?? encoded)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty, seen.insert(token).inserted else { continue }
            tokens.append(token)
        }
        return tokens
    }

    /// What can follow a bare link in prose and is never part of the id it
    /// carries: the sentence's full stop, comma or closing quote, or the `**`
    /// or `_` of Markdown emphasis around it. "foreverlm://notebook/abc." names
    /// `abc`.
    static let trailingLinkPunctuation: Set<Character> = [
        ".", ",", ";", ":", "!", "?", "*", "_", "\"", "'",
        "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}",
    ]

    /// `link` without the prose punctuation after it
    /// (`trailingLinkPunctuation`). Also how a calendar block's links are read
    /// (`CalendarEventLinks`).
    static func trimmingTrailingLinkPunctuation(_ link: Substring) -> Substring {
        var trimmed = link
        while let last = trimmed.last, trailingLinkPunctuation.contains(last) {
            trimmed = trimmed.dropLast()
        }
        return trimmed
    }

    /// The tokens cited across one exchange: the tutor's question or opening,
    /// the learner's message, and the reply.
    static func sourceLinkTokens(question: String?, userAnswer: String?, evaluation: String?) -> [String] {
        let parts = [question, userAnswer, evaluation].compactMap { $0 }.filter { !$0.isEmpty }
        guard parts.contains(where: { $0.range(of: sourceLinkMarker, options: .caseInsensitive) != nil }) else { return [] }
        return sourceLinkTokens(in: parts.joined(separator: "\n"))
    }
}

/// The titles of the sources one chat has met, and the repair of a reply that
/// cites one the way some open "thinking" models do: `【Source title】` instead of
/// `[Source title](foreverlm://source/ID)`.
///
/// The prompts forbid that marker and those models write it anyway, which leaves
/// the citation as dead text: no chip, no Sources card, no way into the Reader.
/// So it is repaired in code, deterministically. A marker whose text is exactly
/// the title of one source this chat has attached, loaded, retrieved or listed
/// (case, spacing and width aside) becomes that source's link. A marker that
/// names nothing, or names two sources alike, keeps its words and loses its
/// brackets: the learner reads the title, and nothing points at a record that
/// may not be the one meant.
struct ChatSourceTitleIndex: Equatable {
    private(set) var titleByID: [String: String] = [:]
    private var idsByTitle: [String: Set<String>] = [:]

    var isEmpty: Bool { titleByID.isEmpty }

    /// Remembers a source the chat has met. The first title seen for an id is
    /// the one a repaired link shows.
    mutating func note(id: String, title: String) {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Self.normalized(shown)
        guard !id.isEmpty, !key.isEmpty else { return }
        if titleByID[id] == nil { titleByID[id] = shown }
        idsByTitle[key, default: []].insert(id)
    }

    /// Remembers every source a tool's answer names, in the three shapes the
    /// app's tools use: a ready-made `[Title](foreverlm://source/ID)` link, a
    /// list line `- [type] Title (id: ID, …)`, and a JSON object carrying
    /// `source_id` beside `title`.
    mutating func harvest(toolResult text: String) {
        guard !text.isEmpty else { return }
        let whole = NSRange(text.startIndex..., in: text)
        for match in Self.linkExpression.matches(in: text, range: whole) {
            guard let titleRange = Range(match.range(at: 1), in: text),
                  let tokenRange = Range(match.range(at: 2), in: text) else { continue }
            let title = String(text[titleRange])
                .replacingOccurrences(of: "\\[", with: "[")
                .replacingOccurrences(of: "\\]", with: "]")
                .replacingOccurrences(of: "\\\\", with: "\\")
            let encoded = String(text[tokenRange])
            note(id: encoded.removingPercentEncoding ?? encoded, title: title)
        }
        for match in Self.listLineExpression.matches(in: text, range: whole) {
            guard let titleRange = Range(match.range(at: 1), in: text),
                  let idRange = Range(match.range(at: 2), in: text) else { continue }
            note(id: String(text[idRange]), title: String(text[titleRange]))
        }
        if let first = text.first(where: { !$0.isWhitespace }), first == "{" || first == "[",
           let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            harvest(json: object)
        }
    }

    private mutating func harvest(json: Any) {
        if let dictionary = json as? [String: Any] {
            if let id = dictionary["source_id"] as? String, let title = dictionary["title"] as? String {
                note(id: id, title: title)
            }
            for value in dictionary.values { harvest(json: value) }
        } else if let array = json as? [Any] {
            for value in array { harvest(json: value) }
        }
    }

    /// `text` with each `【…】` marker repaired. Text without one comes back
    /// untouched and unscanned.
    func repairing(_ text: String) -> String {
        guard text.contains("\u{3010}") else { return text }
        let whole = NSRange(text.startIndex..., in: text)
        let matches = Self.markerExpression.matches(in: text, range: whole)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard let markerRange = Range(match.range, in: result),
                  let innerRange = Range(match.range(at: 1), in: result) else { continue }
            let inner = String(result[innerRange])
            // `【Title†L12-L15】` carries a locator after the dagger.
            let named = inner.split(separator: "\u{2020}", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? inner
            let words = named.trimmingCharacters(in: .whitespacesAndNewlines)
            // A marker already inside a link's brackets must not open a second link.
            let insideBrackets = markerRange.lowerBound > result.startIndex
                && result[result.index(before: markerRange.lowerBound)] == "["
                && result[markerRange.upperBound...].hasPrefix("]")
            if !insideBrackets,
               let ids = idsByTitle[Self.normalized(words)], ids.count == 1, let id = ids.first,
               let title = titleByID[id] {
                result.replaceSubrange(markerRange, with: Self.link(title: title, id: id))
            } else {
                result.replaceSubrange(markerRange, with: words)
            }
        }
        return result
    }

    /// `foreverlm://source/<id>` link text for a source, with a bracket in the
    /// title escaped so it cannot close the link early.
    static func link(title: String, id: String) -> String {
        let text = title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return "[\(text)](\(ChatSourceEvidence.sourceLinkMarker)\(encoded))"
    }

    /// A title as two spellings of it compare: case, accents, width and
    /// runs of spaces set aside.
    static func normalized(_ title: String) -> String {
        title
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static let markerExpression = try! NSRegularExpression(
        pattern: "\u{3010}([^\u{3010}\u{3011}\\n]{1,300})\u{3011}"
    )
    private static let linkExpression = try! NSRegularExpression(
        pattern: ##"\[((?:\\.|[^\]\\\n])+)\]\(foreverlm://source/([^\s)<>'"?#]+)"##
    )
    private static let listLineExpression = try! NSRegularExpression(
        pattern: #"^\s*[-•*]\s*\[[^\]\n]*\]\s+(.+?)\s+\(id:\s*([^,)\s]+)"#,
        options: [.anchorsMatchLines]
    )
}

/// The repair of a reply that cites a source by printing its id: "measured
/// directlysrc_fa3c…", "(src_fa3c…)", "[src_fa3c…]", "`src_fa3c…`", or a link
/// that lost its scheme, `[Title](src_fa3c…)`. The prompts forbid every one of
/// them and models write them anyway, leaving sixty-four hex digits in the
/// answer (product owner, 2026-10-16: "it needs to never put these uuids in
/// the text … it should always show up nicely instead").
///
/// Each becomes the source's `foreverlm://source/` link, which the chat draws as
/// a numbered citation with the source's card below. An id must be whole, or
/// cut short with an ellipsis, so the hex of an id still streaming in is left
/// until it is complete. An id in a link target or a tag attribute (after `/`,
/// `=` or a quote) is already where ids belong and stays as it is.
enum ChatSourceIDCitations {
    /// `text` with every written source id turned into a link. A title from
    /// `titleByID` is the link's text when the chat knows one; the renderer
    /// replaces a citation's text with its number and card either way.
    static func linking(_ text: String, titleByID: [String: String] = [:]) -> String {
        guard text.range(of: "src_", options: .caseInsensitive) != nil else { return text }
        var result = schemelessTargetExpression.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: "](\(ChatSourceEvidence.sourceLinkMarker)$1"
        )
        let matches = writtenIDExpression.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let written = String(result[range])
            let ids = idExpression.matches(in: written, range: NSRange(written.startIndex..., in: written))
                .compactMap { Range($0.range(at: 1), in: written).map { String(written[$0]) } }
            guard !ids.isEmpty else { continue }
            let links = ids.map { id in
                ChatSourceTitleIndex.link(title: title(for: id, in: titleByID) ?? "Source", id: id)
            }
            result.replaceSubrange(range, with: links.joined())
        }
        return result
    }

    /// The title of a whole id, or of the one id a shortened one begins.
    private static func title(for id: String, in titleByID: [String: String]) -> String? {
        if let title = titleByID[id] { return title }
        let matching = titleByID.filter { $0.key.lowercased().hasPrefix(id.lowercased()) }
        return matching.count == 1 ? matching.first?.value : nil
    }

    /// A whole id, or eight or more of its digits and an ellipsis; group 1 is
    /// the id without the ellipsis.
    private static let id = #"(src_(?:[0-9a-f]{64}(?![0-9a-f])|[0-9a-f]{8,63}(?=\x{2026}|\.\.\.)))(?:\x{2026}|\.\.\.)?"#
    /// Ids listed in one wrapper: "src_a, src_b".
    private static let idList = "`?\(id)`?(?:\\s*[,;]\\s*`?\(id)`?)*"

    private static let idExpression = try! NSRegularExpression(pattern: id, options: [.caseInsensitive])

    private static let schemelessTargetExpression = try! NSRegularExpression(
        pattern: #"\]\(\s*"# + id + #"(?=\s|\))"#,
        options: [.caseInsensitive]
    )

    /// An id as visible text, with the wrapper around it and the spaces
    /// before it: the citation sits against the word it follows.
    private static let writtenIDExpression = try! NSRegularExpression(
        pattern: "[ \\t]*(?:"
            + "\\(\\s*(?:(?:source[ _]?)?ids?\\s*[:=]\\s*)?\(idList)\\s*\\)"
            + "|\\[\\s*\(idList)\\s*\\](?!\\()"
            + "|\\x{3010}\\s*\(idList)\\s*\\x{3011}"
            + "|`\(id)`"
            + "|(?<![/=_\\[\"'-])\(id)"
            + ")",
        options: [.caseInsensitive]
    )
}

/// A chat the learner had, as material for the memory review.
///
/// docs/memory-design.md, "Evidence": every chat is evidence, and something the
/// tutor explained in one becomes a next-day retrieval. Reading and listening
/// leave consumption records; a conversation leaves only itself. So an
/// ordinary chat the learner took part in, once enough was said in it, enters
/// the review the way a consumed source does — under the session's own id,
/// typed `chat`, with ideas extracted from its transcript and stamped with the
/// session as their origin — and what was worked out in conversation is asked
/// back the next day, not only what was read.
///
/// The same rules run on the Mac (from SQL) and the phone (from synced
/// records), and the transcript is built identically on both, because its hash
/// is what says whether the ideas already extracted still describe the chat.
enum ReviewableChat {
    /// The `sourceType` a chat carries through the cohort, the briefs and the
    /// tutor. Not a `StudioSourceType`: nothing in the library is a chat.
    static let sourceType = "chat"

    /// How much the tutor has to have said before a chat is worth recalling.
    /// A two-line answer to a lookup question is activity, not learning.
    static let minimumAssistantCharacters = 400

    /// The facts qualification turns on, computed from a session and its
    /// exchanges by whichever client holds them.
    struct Summary: Equatable, Sendable {
        var title: String
        /// `ReviewSessionKind`; nil for a chat recorded before the column.
        var kind: String?
        /// A memory-check launch session carries its planned queue here.
        var hasCardIDs: Bool
        var overallScore: Double?
        /// Messages the learner wrote: a chat nobody took part in is a
        /// scheduled task's output, not theirs.
        var learnerTurns: Int
        /// Characters the tutor produced across the chat.
        var assistantCharacters: Int
        /// Exchanges graded with a score or an idea coverage. A graded
        /// exchange makes the session a review, and a review is evidence about
        /// its sources rather than material of its own.
        var gradedExchanges: Int
        /// Whether a scheduled task's run produced this chat. The Mac knows;
        /// the phone does not sync runs and passes false.
        var isScheduledTaskRun: Bool
        /// When the chat happened, for the ladder: its last answered
        /// exchange, else its end, else its start (`occurredAt`).
        var lastActivityAt: Date

        init(
            title: String,
            kind: String?,
            hasCardIDs: Bool,
            overallScore: Double?,
            learnerTurns: Int,
            assistantCharacters: Int,
            gradedExchanges: Int,
            isScheduledTaskRun: Bool = false,
            lastActivityAt: Date
        ) {
            self.title = title
            self.kind = kind
            self.hasCardIDs = hasCardIDs
            self.overallScore = overallScore
            self.learnerTurns = learnerTurns
            self.assistantCharacters = assistantCharacters
            self.gradedExchanges = gradedExchanges
            self.isScheduledTaskRun = isScheduledTaskRun
            self.lastActivityAt = lastActivityAt
        }
    }

    /// One saved exchange, as much of it as the transcript and the summary need.
    struct Exchange: Equatable, Sendable {
        let sequenceNumber: Int
        /// The tutor's question, or the opening reply of a chat.
        let question: String
        /// The learner's message.
        let userAnswer: String?
        /// The tutor's reply to it.
        let evaluation: String?
        let score: Double?
        let ideaCoverage: String?
        let answeredAt: Date?

        init(
            sequenceNumber: Int,
            question: String,
            userAnswer: String?,
            evaluation: String?,
            score: Double? = nil,
            ideaCoverage: String? = nil,
            answeredAt: Date? = nil
        ) {
            self.sequenceNumber = sequenceNumber
            self.question = question
            self.userAnswer = userAnswer
            self.evaluation = evaluation
            self.score = score
            self.ideaCoverage = ideaCoverage
            self.answeredAt = answeredAt
        }
    }

    /// The summary of a session from its exchanges, for a client that holds
    /// them in memory. The Mac computes the same numbers in SQL.
    static func summary(
        title: String,
        kind: String?,
        hasCardIDs: Bool,
        overallScore: Double?,
        exchanges: [Exchange],
        startedAt: Date,
        endedAt: Date?,
        isScheduledTaskRun: Bool = false
    ) -> Summary {
        Summary(
            title: title,
            kind: kind,
            hasCardIDs: hasCardIDs,
            overallScore: overallScore,
            learnerTurns: exchanges.filter { !trimmed($0.userAnswer).isEmpty }.count,
            assistantCharacters: exchanges.reduce(0) { $0 + $1.question.count + ($1.evaluation?.count ?? 0) },
            gradedExchanges: exchanges.filter { $0.score != nil || $0.ideaCoverage != nil }.count,
            isScheduledTaskRun: isScheduledTaskRun,
            lastActivityAt: occurredAt(exchanges: exchanges, endedAt: endedAt, startedAt: startedAt)
        )
    }

    /// Whether a session is a chat worth recalling: an ordinary chat — not a
    /// memory review, not a graded quiz, not a scheduled task's output — that
    /// the learner took part in and in which enough was said.
    static func qualifies(id: String, status: String, summary: Summary) -> Bool {
        guard status == "active" || status == "completed" else { return false }
        guard summary.kind == nil || summary.kind == ReviewSessionKind.chat.rawValue else { return false }
        guard !MemoryReviewSession.isMemorySession(id) else { return false }
        guard !summary.hasCardIDs, summary.overallScore == nil, !summary.isScheduledTaskRun else { return false }
        guard summary.gradedExchanges == 0, summary.learnerTurns > 0 else { return false }
        return summary.assistantCharacters >= minimumAssistantCharacters
    }

    /// When the chat happened, for the ladder: its last answered exchange, else
    /// its end, else its start.
    static func occurredAt(exchanges: [Exchange], endedAt: Date?, startedAt: Date) -> Date {
        exchanges.compactMap(\.answeredAt).max() ?? endedAt ?? startedAt
    }

    /// The transcript ideas are extracted from, and whose hash says whether
    /// the stored ideas still describe the chat. Turn order is the exchange
    /// order; within an exchange the tutor's question, the learner's message,
    /// the tutor's reply. The title leads, so a chat that opens on a source
    /// still says what it was about.
    static func transcript(title: String, exchanges: [Exchange]) -> String {
        var turns: [ConversationTranscriptFormatter.Turn] = []
        for exchange in exchanges.sorted(by: { $0.sequenceNumber < $1.sequenceNumber }) {
            if !trimmed(exchange.question).isEmpty {
                turns.append(.init(speaker: .assistant, content: exchange.question))
            }
            if !trimmed(exchange.userAnswer).isEmpty {
                turns.append(.init(speaker: .user, content: exchange.userAnswer ?? ""))
            }
            if !trimmed(exchange.evaluation).isEmpty {
                turns.append(.init(speaker: .assistant, content: exchange.evaluation ?? ""))
            }
        }
        let body = ConversationTranscriptFormatter.plainText(from: turns)
        let heading = trimmed(title)
        return heading.isEmpty ? body : "CHAT: \(heading)\n\n\(body)"
    }

    /// What the tutor is told about a chat in its brief, so it asks for what
    /// the learner took away rather than for a source they never read.
    static let tutorNote = "THIS IS A CONVERSATION they had with ForeverLM, not a source. Its contour is what they took away: ask them to say, unaided, what they worked out or learned in that chat. There is nothing for them to open or read; the excerpt under \"What it says\" is the transcript, for you alone."

    private static func trimmed(_ text: String?) -> String {
        var content = Substring(text ?? "")
        while content.first?.isWhitespace == true { content.removeFirst() }
        while content.last?.isWhitespace == true { content.removeLast() }
        return String(content)
    }
}
