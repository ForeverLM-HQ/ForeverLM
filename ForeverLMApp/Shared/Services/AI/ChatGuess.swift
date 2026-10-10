import Foundation

/// A guess the learner wrote before asking a question in a notebook's chat:
/// Think first's chat moment (docs/fences-and-think-first-design.md, "Think
/// first", the third level). The question goes as asked; the guess travels
/// beside it, in their words, and the answer ends with one short paragraph on
/// where the guess and the answer agree and differ. Never a grade.
///
/// The mark travels beside the message, never in it, like a side question
/// (`ChatSideQuestion`): one line at the top of the exchange's
/// `context_content`, the model-only column, in the place a side question's
/// mark would take (under any sources-added, skill or plugin mark, above the
/// reference material). A message is a side question or a guessed question,
/// never both. `ChatSideQuestion.parse` reads the mark off, so every reader of
/// the reference material sees what it saw before the mark existed. The line
/// is JSON with sorted keys, so a guess on several lines stays one line:
///
///     <flm_guess>{"guess":"…"}</flm_guess>
///
/// The web writes the same bytes and reads the same mark
/// (`docs-site/website/library`), so a guess sent from either is drawn by both.
/// Foundation only, like the other marks.
enum ChatGuess {

    /// Persisted in `context_content` rows and synced, so the stored tag keeps
    /// its spelling.
    static let tagName = "flm_guess"

    private static let openingTag = "<\(tagName)>"
    private static let closingTag = "</\(tagName)>"

    private struct Payload: Codable {
        var guess: String
    }

    /// The one-line mark for a guess, or nil for one with no words.
    static func marker(guess: String) -> String? {
        let trimmed = guess.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(Payload(guess: trimmed)),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return openingTag + json + closingTag
    }

    /// What a guessed question stores beside itself: the mark, over whatever
    /// reference material the message carried anyway (a quoted passage).
    static func contextContent(guess: String, referenceContext: String?) -> String? {
        let reference = referenceContext?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let mark = marker(guess: guess) else {
            return reference?.isEmpty == false ? reference : nil
        }
        guard let reference, !reference.isEmpty else { return mark }
        return mark + "\n" + reference
    }

    /// The guess on top of `content`, and what is left under it; nil when the
    /// first line is no guess mark (or one that cannot be read, which then
    /// stays as it was).
    static func take(from content: String) -> (guess: String, remainder: String?)? {
        let firstLineEnd = content.firstIndex(where: \.isNewline) ?? content.endIndex
        let firstLine = content[..<firstLineEnd].trimmingCharacters(in: .whitespaces)
        guard firstLine.hasPrefix(openingTag), firstLine.hasSuffix(closingTag),
              firstLine.count > openingTag.count + closingTag.count else { return nil }
        let json = firstLine.dropFirst(openingTag.count).dropLast(closingTag.count)
        guard let data = String(json).data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              !payload.guess.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let rest = String(content[firstLineEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (payload.guess, rest.isEmpty ? nil : rest)
    }

    /// The guess a learner message carried, read off its stored context
    /// through the same marks `ChatSideQuestion.parse` takes off first.
    static func guess(contextContent: String?) -> String? {
        let plugin = ChatPluginRequest.parse(contextContent: contextContent)
        return ChatSideQuestion.parse(contextContent: plugin.remainder).guess
    }

    // MARK: - What the model is told

    /// Appended to the learner's turn, outside the reference wrapper, because
    /// it is the learner's own. The web appends the same words.
    static func framing(guess: String) -> String {
        """
        <learner_guess>
        Before asking, the learner wrote their own guess at the answer, in their words: \u{201C}\(guess)\u{201D}
        Answer their question as you would have anyway. Then end with one short paragraph that begins "Your guess:" and says where their guess and your answer agree and where they differ: what their guess saw that your answer leaves out, as well as what it missed. Do not grade, score or praise it.
        </learner_guess>
        """
    }

    /// Whether a message asks something Think first may ask a guess for: it
    /// ends in a question mark. A deterministic structural test, not a
    /// reading of the words; a question phrased as a request goes as usual.
    static func isQuestion(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
    }
}
