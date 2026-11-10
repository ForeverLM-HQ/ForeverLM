import Foundation

/// A skill the learner wrote for the chat (product owner, 2026-09-24: "just like
/// we're adding basically the ability to do a paper walkthrough with cards as
/// a skill I think people should be able to do that regardless like add their
/// own skills to the app").
///
/// A skill is the shape of Claude's `SKILL.md`: a short name, one description
/// that says when it applies, and instructions in markdown that say how to do
/// the work. The chat carries every skill's name and description in its
/// system prompt and reads a skill's instructions with `get_skill` when a
/// request matches it; the learner can also call one by name, `/name`, in the
/// composer, which puts the instructions beside that message
/// (`ChatSkillRequest`). See docs/chat-design.md, "Skills".
///
/// The name is the command, so it is kept to what a `/` token can hold:
/// lowercase letters, digits and hyphens (`normalizedName`). It is the
/// learner's handle on the skill, not its identity — `id` is — so two Macs
/// that each wrote a `walkthrough` skill keep both rather than failing a
/// sync, and a lookup by name takes the most recently edited.
struct SkillRecord: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: String
    var name: String
    var description: String
    var instructions: String
    let createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        name: String,
        description: String,
        instructions: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.instructions = instructions
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Limits

    /// Claude's own limit on a skill name.
    static let nameLimit = 64
    /// Claude's own limit on a skill description. The description rides in
    /// every chat's system prompt, so it is kept to a paragraph.
    static let descriptionLimit = 1_024
    /// The instructions are read only when the skill is used; this bounds one
    /// tool result, not the prompt.
    static let instructionsLimit = 100_000

    // MARK: - Normalizing

    /// The name as a `/` command: lowercased, every run of spaces,
    /// underscores or other separators turned into one hyphen, anything that
    /// is not a letter or digit dropped, and no hyphen at either end.
    /// `"Paper Walkthrough"` → `paper-walkthrough`. Empty when nothing usable
    /// was typed.
    static func normalizedName(_ raw: String) -> String {
        var result = ""
        var pendingHyphen = false
        for scalar in raw.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                if pendingHyphen, !result.isEmpty { result.append("-") }
                pendingHyphen = false
                result.unicodeScalars.append(scalar)
            } else if scalar == "-" || scalar == "_" || CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar == "." || scalar == "/" {
                pendingHyphen = true
            }
            if result.count >= nameLimit { break }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result
    }

    /// One paragraph: trimmed, whitespace runs folded into single spaces.
    static func normalizedDescription(_ raw: String) -> String {
        let folded = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(folded.prefix(descriptionLimit))
    }

    static func normalizedInstructions(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The chat composer's own commands (`ReviewSlashCommand.all`, App). A
    /// skill of one of these names could never be called with `/`, so the
    /// name is refused; `SkillSlashCommandTests` keeps the two lists equal.
    static let reservedNames: Set<String> = [
        "goal", "source", "page", "doc", "site", "site-prompt", "animate", "video", "course",
        "today", "plan", "review", "notebook", "new", "model",
        "settings", "clear", "end", "help",
        "rename", "pin", "hide", "fork", "side", "reasoning",
    ]

    /// Why a skill cannot be saved as given, or nil when it can.
    static func validationProblem(name: String, description: String, instructions: String) -> String? {
        let normalized = normalizedName(name)
        if normalized.isEmpty {
            return "A skill needs a name made of letters, digits or hyphens — it is what you type after /."
        }
        if reservedNames.contains(normalized) {
            return "/\(normalized) is one of ForeverLM's own commands. Pick another name."
        }
        if normalizedDescription(description).isEmpty {
            return "A skill needs a description: the chat reads it to decide when the skill applies."
        }
        let body = normalizedInstructions(instructions)
        if body.isEmpty {
            return "A skill needs instructions: what the chat should do when it uses the skill."
        }
        if body.count > instructionsLimit {
            return "Instructions are limited to \(instructionsLimit.formatted()) characters."
        }
        return nil
    }

    // MARK: - SKILL.md

    /// The skill as a `SKILL.md` file, the format Claude, Codex and the
    /// Gemini CLI read, so a skill written here can be taken to them.
    var skillMarkdown: String {
        """
        ---
        name: \(name)
        description: \(Self.frontmatterScalar(description))
        ---

        \(instructions)

        """
    }

    /// What a `SKILL.md` file says: its frontmatter's `name` and
    /// `description`, and the markdown under it as the instructions. This
    /// reads the file's structure — YAML frontmatter between `---` lines —
    /// and nothing about its meaning. A plain value, a quoted one, and a
    /// folded (`>`) or literal (`|`) block are read; any other key is
    /// ignored. nil when the file has no frontmatter.
    struct ParsedMarkdown: Equatable, Sendable {
        var name: String?
        var description: String?
        var instructions: String
    }

    static func parseSkillMarkdown(_ text: String) -> ParsedMarkdown? {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
        var lines = normalized.components(separatedBy: "\n")
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        guard let closing = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return nil
        }
        let frontmatter = Array(lines[1..<closing])
        let body = lines[(closing + 1)...].joined(separator: "\n")

        var values: [String: String] = [:]
        var index = 0
        while index < frontmatter.count {
            let line = frontmatter[index]
            index += 1
            // A top-level key starts at column zero; indented lines belong to
            // the block above them.
            guard let first = line.first, !first.isWhitespace, first != "#",
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let rawValue = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if rawValue.hasPrefix(">") || rawValue.hasPrefix("|") {
                var block: [String] = []
                while index < frontmatter.count {
                    let next = frontmatter[index]
                    if let c = next.first, !c.isWhitespace { break }
                    block.append(next.trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                values[key] = rawValue.hasPrefix(">")
                    ? block.filter { !$0.isEmpty }.joined(separator: " ")
                    : block.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                values[key] = unquotedScalar(rawValue)
            }
        }
        return ParsedMarkdown(
            name: values["name"].flatMap { $0.isEmpty ? nil : $0 },
            description: values["description"].flatMap { $0.isEmpty ? nil : $0 },
            instructions: normalizedInstructions(body)
        )
    }

    private static func unquotedScalar(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, let last = value.last,
              (first == "\"" && last == "\"") || (first == "'" && last == "'") else {
            return value
        }
        let inner = String(value.dropFirst().dropLast())
        if first == "'" { return inner.replacingOccurrences(of: "''", with: "'") }
        return inner
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// A description written back as frontmatter: plain when YAML reads it
    /// plainly, double-quoted when a colon, a leading symbol or a quote would
    /// change its meaning.
    private static func frontmatterScalar(_ value: String) -> String {
        let needsQuoting = value.contains(": ") || value.contains(" #") || value.hasSuffix(":")
            || value.first.map { "!&*[]{}|>'\"%@`#,?-".contains($0) } == true
        guard needsQuoting else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

extension Array where Element == SkillRecord {
    /// The skill a name calls: the most recently edited one with that name.
    func skill(named rawName: String) -> SkillRecord? {
        let name = SkillRecord.normalizedName(rawName)
        guard !name.isEmpty else { return nil }
        return filter { $0.name == name }.max { $0.updatedAt < $1.updatedAt }
    }
}

