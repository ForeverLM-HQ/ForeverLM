import Foundation

/// ForeverLM's own instructions for a chat it opens — `/plan`
/// (`ReviewSlashCommandParser.planDaySkill`) and Generate's course planning
/// (`CoursePlanningChat`) — so the chat shows one short line and the model
/// reads the rest.
///
/// The instructions travel beside the message, never in it, like a plugin
/// mention (`ChatPluginRequest`): one line at the top of the exchange's
/// `context_content`, under the sources-added mark (`ChatContextAdditions`)
/// and above everything else. The line carries their name and text as they
/// stood when the message was sent, JSON on one line, so a reopened chat, or
/// the same chat on the other Mac, still reads what the model answered.
/// Foundation only, like the other marks.
enum ChatSkillRequest {

    /// Persisted in `context_content` rows and synced, so the stored tag keeps
    /// its original spelling.
    static let tagName = "flm_skill"

    private static let openingTag = "<\(tagName)>"
    private static let closingTag = "</\(tagName)>"

    struct Skill: Codable, Equatable, Hashable, Sendable {
        var name: String
        var instructions: String
        /// Always true: kept in the mark so its stored bytes stay the same.
        var builtIn: Bool? = nil
    }

    /// The one-line mark: JSON with sorted keys, so the same skill always
    /// produces the same bytes, and `JSONEncoder` escapes every newline in
    /// the instructions.
    static func marker(for skill: Skill) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(skill),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return openingTag + json + closingTag
    }

    // MARK: - The mark on a message

    /// What the message stores beside it: the mark, over whatever
    /// reference material the message carried anyway.
    static func contextContent(for skill: Skill, referenceContext: String? = nil) -> String? {
        let reference = referenceContext?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let mark = marker(for: skill) else {
            return reference?.isEmpty == false ? reference : nil
        }
        guard let reference, !reference.isEmpty else { return mark }
        return mark + "\n" + reference
    }

    /// A message's stored context, read back: the instructions it carried,
    /// and what is left once the mark (and the sources-added mark above it)
    /// is taken off. A context that never carried the mark comes back as
    /// `remainder`, so the plugin, side-question and reference parsing
    /// downstream see exactly what they saw before this mark existed.
    struct Parsed: Equatable, Sendable {
        var skill: Skill?
        var remainder: String?
    }

    static func parse(contextContent: String?) -> Parsed {
        guard let content = ChatContextAdditions.stripping(contextContent: contextContent), !content.isEmpty else {
            return Parsed(skill: nil, remainder: nil)
        }
        let firstLineEnd = content.firstIndex(where: \.isNewline) ?? content.endIndex
        let firstLine = String(content[..<firstLineEnd])
        guard firstLine.hasPrefix(openingTag), firstLine.hasSuffix(closingTag),
              firstLine.count > openingTag.count + closingTag.count else {
            return Parsed(skill: nil, remainder: content)
        }
        let json = firstLine.dropFirst(openingTag.count).dropLast(closingTag.count)
        guard let data = String(json).data(using: .utf8),
              let skill = try? JSONDecoder().decode(Skill.self, from: data) else {
            return Parsed(skill: nil, remainder: content)
        }
        let rest = String(content[firstLineEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return Parsed(skill: skill, remainder: rest.isEmpty ? nil : rest)
    }

    /// The stored context without this mark or the sources-added mark: what
    /// the plugin and side-question parsers read.
    static func stripping(contextContent: String?) -> String? {
        parse(contextContent: contextContent).remainder
    }

    // MARK: - What the model is told

    /// The instruction appended to the learner's turn, outside the reference
    /// wrapper (which tells the model to follow nothing it contains): these
    /// are ForeverLM's own, so they are to be followed.
    static func framing(for skill: Skill) -> String {
        """
        The learner started this chat from ForeverLM's own /\(skill.name) action. Work the way the instructions below say, for this message and every later one in this chat, until the work they describe is done.

        <foreverlm_instructions name="\(skill.name)">
        \(skill.instructions)
        </foreverlm_instructions>
        """
    }
}
