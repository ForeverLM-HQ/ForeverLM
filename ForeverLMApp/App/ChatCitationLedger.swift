import Foundation

/// Which source each `[n]` in a review transcript means.
///
/// The chat renderer sees one reply at a time — on the Mac every assistant
/// message draws in its own web view — so left to itself it can only number the
/// sources that reply cites, from one, and `[1]` quietly means a different work
/// in two adjacent replies as soon as a second source appears. The numbering is
/// a fact about the transcript rather than about a message, so it is settled
/// here and handed to the page with the markdown: a source keeps one number for
/// the whole conversation.
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

        var isEmpty: Bool { numbers.isEmpty }
    }

    /// The context for each message in a transcript, in order. Messages that
    /// cite nothing are absent: they have nothing to number.
    ///
    /// `open` is the reply still being written, if there is one. What it will
    /// cite is not known yet, so instead of the sources it cites so far -- none,
    /// when it is empty -- it receives the whole cast the transcript has
    /// introduced above it, so a fresh reply that returns to a source already
    /// cited keeps that source's number from its first paint.
    static func contexts(for messages: [Entry], open: UUID? = nil) -> [UUID: MessageContext] {
        var numbers: [String: Int] = [:]
        var contexts: [UUID: MessageContext] = [:]

        for message in messages {
            let cited = citations(in: message.markdown)
            let isOpen = message.id == open
            guard !cited.isEmpty || isOpen else { continue }

            var context = MessageContext()
            if isOpen { context.numbers = numbers }
            for citation in cited {
                let number = numbers[citation.token] ?? (numbers.count + 1)
                numbers[citation.token] = number
                context.numbers[citation.token] = number
            }
            contexts[message.id] = context
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
