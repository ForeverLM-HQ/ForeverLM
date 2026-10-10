import Foundation

/// The passage of a source a chat was opened on, read back off the message
/// that carried it.
///
/// Pressing Chat on a reader selection sends the passage beside the first
/// message as model-only context (`ReaderSelectionExplanationRequest
/// .contextualContent`): a "Selected passage:" heading, the words as a
/// blockquote, the source's title under "Context:". That block is stored in
/// `review_exchanges.context_content` and synced, but until 2026-09-20 nothing
/// ever drew it again — the chat showed the question and the answer, and the
/// highlighted words the whole conversation was about were nowhere on screen
/// (the product owner). The chat now reads the block back and draws the passage as a
/// quote in the bubble of the message it was asked with, and a click on the
/// quote opens the source in the Reader at those words.
///
/// The block also carries the source's id from now on, on a `Source ID:` line
/// beside the `Article ID:` line a doc passage already had, so the quote knows
/// exactly which source to open. A chat from before that line names no source
/// here; the pane falls back to the chat's own sources.
///
/// Foundation only, like the marks that may sit above the block
/// (`ChatContextAdditions`, `ChatPluginRequest`, `ChatSideQuestion`), so every
/// client reads the same words.
enum ChatPassageOrigin {

    /// A passage a learner message was asked about, and where it came from.
    struct Passage: Equatable, Sendable {
        /// The words, as the learner selected them, without the `> ` dressing.
        var quote: String
        /// The source the passage was selected in, when the block names it.
        var sourceID: String?
        /// The `Context:` label the block carries — the source's title, for a
        /// reader selection — so a source the block does not name can still
        /// be found among the chat's sources by title.
        var contextTitle: String?
    }

    static let heading = "Selected passage:"
    static let sourceIDPrefix = "Source ID: "
    static let contextPrefix = "Context: "
    /// A doc passage's own identity line. A block carrying it is a doc's, and a
    /// doc passage is recorded and drawn elsewhere (`artifact_chat_links`).
    static let docIDPrefix = "Article ID: "

    /// The `Source ID:` line for a reader selection's block, or nil when the
    /// selection names no single source.
    static func sourceIDLine(for sourceIDs: [String]) -> String? {
        let ids = sourceIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard ids.count == 1, let id = ids.first else { return nil }
        return sourceIDPrefix + id
    }

    /// The source passage a stored context carries, or nil when the message
    /// was sent with none: no context, a doc's passage, a review exchange, a
    /// side question with nothing quoted, or reference material of another
    /// shape.
    static func parse(contextContent: String?) -> Passage? {
        // The marks above the block come off in the order the manager reads
        // them; what is left is the reference material the message carried.
        let plugin = ChatPluginRequest.parse(contextContent: contextContent)
        guard let reference = ChatSideQuestion.parse(contextContent: plugin.remainder).referenceContext else {
            return nil
        }
        var lines = reference.components(separatedBy: .newlines)[...]
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces), first == heading else { return nil }
        lines = lines.dropFirst()

        var quoteLines: [String] = []
        while let line = lines.first {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(">") else { break }
            var text = trimmed.dropFirst()
            if text.hasPrefix(" ") { text = text.dropFirst() }
            quoteLines.append(String(text))
            lines = lines.dropFirst()
        }
        let quote = quoteLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty else { return nil }

        var sourceID: String?
        var contextTitle: String?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(docIDPrefix) { return nil }
            if trimmed.hasPrefix(sourceIDPrefix) {
                let id = trimmed.dropFirst(sourceIDPrefix.count).trimmingCharacters(in: .whitespaces)
                if !id.isEmpty { sourceID = id }
            } else if trimmed.hasPrefix(contextPrefix), contextTitle == nil {
                let title = trimmed.dropFirst(contextPrefix.count).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { contextTitle = title }
            }
        }
        return Passage(quote: quote, sourceID: sourceID, contextTitle: contextTitle)
    }
}
