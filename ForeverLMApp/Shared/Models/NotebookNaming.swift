import Foundation

/// A new notebook needs no name (product owner, 2026-10-03: "not sure we need to
/// fill this in when we make a new notebook; title etc can be auto generated
/// after we add sources and start chatting"). It is made at once under a
/// placeholder, and ForeverLM names it, title and card description, from what
/// it holds: its sources, then the first exchange of its chats
/// (docs/notebooks-design.md, "A notebook names itself").
///
/// What lets ForeverLM rename a notebook is one synced preference row per
/// notebook, `notebook.naming.<notebookID>`, never a column on the Notebook
/// record (no schema change): the name and description ForeverLM last put on
/// it (`Mark`). No row is a name ForeverLM leaves alone — every notebook made
/// before this, every notebook made with a name, and every notebook whose name
/// or description the learner typed, since each learner edit removes the row.
/// And a row only counts while the notebook still carries exactly the title and
/// description it names, so an edit from a device that never heard of the row
/// is not overwritten either.
enum NotebookNaming {
    /// What a notebook is called until it is named.
    static let placeholderTitle = "New notebook"

    static func preferenceKey(notebookID: String) -> String {
        Prefs.Families.notebookNaming.prefix + notebookID
    }

    /// The name ForeverLM last put on a notebook: the placeholder while it is
    /// unnamed, then its own. `sources` and `exchanges` are what it was named
    /// from, nil until it has been.
    struct Mark: Codable, Equatable, Sendable {
        var title: String
        var summary: String?
        var sources: Int?
        var exchanges: Int?

        var isNamed: Bool { sources != nil }

        static func unnamed(title: String) -> Mark {
            Mark(title: title, summary: nil, sources: nil, exchanges: nil)
        }

        /// The row's stored form: a JSON string, which every client reads.
        var encoded: String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else {
                preconditionFailure("A notebook naming mark always encodes")
            }
            return text
        }

        /// nil for anything that is not a mark, which reads as no row.
        static func decoded(_ raw: Any?) -> Mark? {
            guard let text = raw as? String, let data = text.data(using: .utf8),
                  let mark = try? JSONDecoder().decode(Mark.self, from: data),
                  !mark.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return mark
        }
    }

    /// The placeholder for one more notebook: "New notebook", or "New
    /// notebook 2", 3… while that name is taken, so two unnamed notebooks on
    /// the home are told apart.
    static func placeholder(existingTitles: [String]) -> String {
        let taken = Set(existingTitles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        guard taken.contains(placeholderTitle.lowercased()) else { return placeholderTitle }
        var number = 2
        while taken.contains("\(placeholderTitle) \(number)".lowercased()) { number += 1 }
        return "\(placeholderTitle) \(number)"
    }

    /// Whether `title` is a placeholder ("New notebook", "New notebook 2"…):
    /// a name that says nothing of what the notebook is about, so nothing is
    /// suggested from it.
    static func isPlaceholder(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = placeholderTitle.lowercased()
        if trimmed == base { return true }
        guard trimmed.hasPrefix(base + " ") else { return false }
        let number = trimmed.dropFirst(base.count + 1)
        return !number.isEmpty && number.allSatisfy(\.isNumber)
    }

    enum Decision: Equatable, Sendable {
        /// ForeverLM leaves the name alone.
        case keep
        /// The notebook holds something for the first time: name it.
        case name
        /// Named from little, it holds more now: name it once more, the last time.
        case sharpen
    }

    /// Whether ForeverLM names the notebook now. Nothing without a row; nothing
    /// once the notebook's title or description is not what the row says (the
    /// learner, or another device, named it); an unnamed notebook as soon as it
    /// holds a source or a chat exchange; a named one once more when two more
    /// sources have come, or its first chat exchange after it was named from
    /// sources alone.
    static func decision(mark: Mark?, title: String, summary: String?, sources: Int, exchanges: Int) -> Decision {
        guard let mark, carries(mark, title: title, summary: summary) else { return .keep }
        guard let namedSources = mark.sources else {
            return sources + exchanges > 0 ? .name : .keep
        }
        let namedExchanges = mark.exchanges ?? 0
        if sources >= namedSources + 2 { return .sharpen }
        if namedExchanges == 0, exchanges > 0 { return .sharpen }
        return .keep
    }

    /// Whether the notebook still carries the name and description the row
    /// says ForeverLM put on it.
    static func carries(_ mark: Mark, title: String, summary: String?) -> Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines) == mark.title.trimmingCharacters(in: .whitespacesAndNewlines)
            && normalized(summary) == normalized(mark.summary)
    }

    private static func normalized(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - The model's turn

    /// What the naming call reads.
    struct Request: Equatable, Sendable {
        struct Source: Equatable, Sendable {
            var title: String
            var kind: String
            /// The opening of its text, standing in for an abstract.
            var opening: String
        }
        struct Exchange: Equatable, Sendable {
            var chatTitle: String
            var learner: String
            var reply: String
        }
        var notebookID: String
        var currentTitle: String
        var instructions: String?
        var sources: [Source]
        var exchanges: [Exchange]
    }

    /// At most this many sources and chats are read; the rest are counted.
    static let maximumSources = 12
    static let maximumExchanges = 3
    static let sourceOpeningCharacters = 600
    static let exchangeCharacters = 900
    /// The stored caps, in characters, for what the model writes.
    static let maximumTitleLength = 90

    /// The learner's notebook as the model reads it: what they are learning,
    /// each source with the opening of its text, then the first exchange of
    /// each chat.
    static func userMessage(_ request: Request, totalSources: Int) -> String {
        var lines: [String] = []
        if let instructions = request.instructions?.trimmingCharacters(in: .whitespacesAndNewlines), !instructions.isEmpty {
            lines.append("What the learner said they are trying to learn: \(instructions)")
            lines.append("")
        }
        if !request.sources.isEmpty {
            lines.append("Sources in the notebook (\(totalSources)):")
            for (index, source) in request.sources.enumerated() {
                lines.append("")
                lines.append("\(index + 1). \(source.title) [\(source.kind)]")
                let opening = clipped(source.opening, to: sourceOpeningCharacters)
                if !opening.isEmpty { lines.append(opening) }
            }
            if totalSources > request.sources.count {
                lines.append("")
                lines.append("… and \(totalSources - request.sources.count) more.")
            }
        }
        if !request.exchanges.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append("How the learner's chats in it began:")
            for exchange in request.exchanges {
                lines.append("")
                lines.append("Learner: \(clipped(exchange.learner, to: exchangeCharacters))")
                lines.append("ForeverLM: \(clipped(exchange.reply, to: exchangeCharacters))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func clipped(_ text: String, to limit: Int) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }

    /// The name and card line the model wrote.
    struct Answer: Equatable, Sendable {
        var title: String
        var summary: String?
    }

    enum AnswerError: Error, Equatable {
        case unreadable
        case noTitle
    }

    /// Reads `{"title": …, "description": …}`. A title is required and kept to
    /// one line; a description is optional and stored as `NotebookSummary`
    /// stores every card line.
    static func answer(from response: String) throws -> Answer {
        struct Draft: Decodable {
            var title: String?
            var description: String?
        }
        guard let data = jsonObjectText(in: response)?.data(using: .utf8),
              let draft = try? JSONDecoder().decode(Draft.self, from: data) else {
            throw AnswerError.unreadable
        }
        let title = oneLine(draft.title ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'‘’").union(.whitespacesAndNewlines))
        guard !title.isEmpty else { throw AnswerError.noTitle }
        let summary = NotebookSummary.normalized(draft.description)
        return Answer(title: String(title.prefix(maximumTitleLength)), summary: summary)
    }

    /// The outermost `{…}` of a reply, so a fenced or prefaced answer reads.
    private static func jsonObjectText(in response: String) -> String? {
        guard let start = response.firstIndex(of: "{"), let end = response.lastIndex(of: "}"), start < end else {
            return nil
        }
        return String(response[start...end])
    }

    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
