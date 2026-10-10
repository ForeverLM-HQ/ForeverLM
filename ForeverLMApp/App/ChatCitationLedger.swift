import Foundation

/// Which source each `[n]` in a review transcript means, and which sources the
/// conversation has already put a card under.
///
/// The chat renderer sees one reply at a time — on the Mac every assistant
/// message draws in its own web view — so left to itself it can only number the
/// sources that reply cites, from one, and list every one of them underneath.
/// In a review that circles a single paper for forty turns that is the same
/// title, byline and thumbnail forty times, and `[1]` quietly means a different
/// work in two adjacent replies as soon as a second source appears.
///
/// Both are facts about the transcript rather than about a message, so they are
/// settled here and handed to the page with the markdown. A source keeps one
/// number for the whole conversation, and its card is listed the first time the
/// conversation reaches for it — again later only when a reply points at a
/// moment of it that no earlier reply pointed at.
enum ChatCitationLedger {
    /// One `foreverlm://source/<token>[?t=…]` link, as written.
    struct Citation: Equatable {
        let token: String
        /// The moment the link asks for, rounded to the second the way the
        /// renderer rounds it back into a chip's href, or nil for the source as
        /// a whole.
        let seconds: Int?
    }

    /// A message as the ledger reads it: what identifies its row, and the
    /// markdown that row renders. Only messages the transcript actually draws
    /// as markdown belong here — a user's own turn is plain text and its links
    /// are not citations.
    struct Entry {
        let id: UUID
        let markdown: String

        init(id: UUID, markdown: String) {
            self.id = id
            self.markdown = markdown
        }
    }

    /// What one reply needs to know about the transcript above it. Encodes as
    /// the object `window.setCitationContext` takes, and carries only the
    /// sources that reply cites rather than the session's whole cast -- except
    /// for the reply still being written, which gets the cast because what it
    /// will cite is not settled yet.
    struct MessageContext: Equatable, Encodable {
        /// Source token → the number it keeps for the whole conversation.
        var numbers: [String: Int] = [:]
        /// Source token → the moments an earlier reply already listed under its
        /// card. Present at all means the card has been shown; empty means it
        /// was shown for the source as a whole, pointing at no moment.
        var presented: [String: [Int]] = [:]

        var isEmpty: Bool { numbers.isEmpty && presented.isEmpty }
    }

    /// The context for each message in a transcript, in order. Messages that
    /// cite nothing are absent: they have nothing to number and nothing to
    /// suppress.
    ///
    /// `open` is the reply still being written, if there is one. What it will
    /// cite is not known yet, so instead of the sources it cites so far -- none,
    /// when it is empty -- it receives the whole cast the transcript has
    /// introduced above it. Without that, a fresh reply that returns to the one
    /// source a review is about would list that source again under every turn
    /// until the next message arrived and the ledger looked at it a second time.
    static func contexts(for messages: [Entry], open: UUID? = nil) -> [UUID: MessageContext] {
        var numbers: [String: Int] = [:]
        var presented: [String: Set<Int>] = [:]
        var contexts: [UUID: MessageContext] = [:]

        for message in messages {
            let cited = citations(in: message.markdown)
            let isOpen = message.id == open
            guard !cited.isEmpty || isOpen else { continue }

            var context = MessageContext()
            if isOpen {
                context.numbers = numbers
                context.presented = presented.mapValues { $0.sorted() }
            }
            for citation in cited {
                let number = numbers[citation.token] ?? (numbers.count + 1)
                numbers[citation.token] = number
                context.numbers[citation.token] = number
                if let shown = presented[citation.token] {
                    context.presented[citation.token] = shown.sorted()
                }
            }
            contexts[message.id] = context

            // Whatever this reply cites is on screen from here on. Recording a
            // suppressed reply's moments changes nothing — they are already
            // here, which is why it was suppressed.
            for citation in cited {
                var shown = presented[citation.token] ?? []
                if let seconds = citation.seconds { shown.insert(seconds) }
                presented[citation.token] = shown
            }
        }

        return contexts
    }

    /// Every source link in a reply, in the order it was written and keeping
    /// repeats: the same source cited at two moments is two citations, and the
    /// order is what decides the numbering.
    static func citations(in markdown: String) -> [Citation] {
        guard let expression = linkExpression else { return [] }

        let range = NSRange(markdown.startIndex..., in: markdown)
        var citations: [Citation] = []
        for match in expression.matches(in: markdown, range: range) {
            guard let tokenRange = Range(match.range(at: 1), in: markdown) else { continue }
            let encoded = String(markdown[tokenRange])
            let token = (encoded.removingPercentEncoding ?? encoded)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }

            let query = Range(match.range(at: 2), in: markdown).map { String(markdown[$0]) }
            citations.append(Citation(token: token, seconds: moment(inQuery: query)))
        }
        return citations
    }

    /// Same shape the app's own link validation matches, plus the query, so a
    /// timed citation is read here exactly as the renderer reads it. The token
    /// stops at whatever ends a markdown link.
    private static let linkExpression = try? NSRegularExpression(
        pattern: ##"foreverlm://source/([^\s)<>'"?#]+)(?:\?([^\s)<>'"#]*))?"##,
        options: [.caseInsensitive]
    )

    private static func moment(inQuery query: String?) -> Int? {
        guard let query, !query.isEmpty else { return nil }
        let value = query
            .split(separator: "&", omittingEmptySubsequences: true)
            .compactMap { item -> String? in
                let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, parts[0] == SourceLinkTimeAnchor.queryItemName else { return nil }
                let raw = String(parts[1]).replacingOccurrences(of: "+", with: " ")
                return raw.removingPercentEncoding ?? raw
            }
            .first
        guard let seconds = SourceLinkTimeAnchor.seconds(from: value) else { return nil }
        return Int(seconds.rounded())
    }
}
