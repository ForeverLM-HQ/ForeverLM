import Foundation

/// A message the learner addressed to a plugin — `@slack`, `@linear`,
/// `@github`, `@notion` in the composer — is a question about that service, and the model
/// has to read the service live in this turn rather than search the library or
/// answer from memory.
///
/// The mark travels beside the message, never in it: a tag line at the top of
/// the exchange's `context_content`, the model-only column that already carries
/// a quoted passage and the side-question mark (`ChatSideQuestion`). That keeps
/// the learner's words their own in the transcript, survives a reload, and syncs
/// to the other Mac, where a reopened chat still knows the question was about
/// Slack. Foundation only, like `ChatSideQuestion`, so every client reads the
/// same mark.
enum ChatPluginRequest {

    /// A workspace plugin the chat reads live through the MCP gateway. The
    /// raw value is the mention's name (`@slack`) and the tag's `name` attribute.
    enum Plugin: String, CaseIterable, Hashable, Sendable {
        case slack
        case linear
        case github
        case notion
    }

    /// Persisted at the top of `context_content` rows and synced between Macs,
    /// so the stored tag keeps its original spelling.
    static let tagName = "flm_connector"

    /// The line that marks an exchange as a plugin request.
    static func marker(for plugin: Plugin) -> String {
        "<\(tagName) name=\"\(plugin.rawValue)\"/>"
    }

    // MARK: - The mark on a message

    /// What a plugin mention stores beside its message: the mark, over
    /// whatever reference material the message carried anyway.
    static func contextContent(for plugin: Plugin, referenceContext: String? = nil) -> String {
        var lines = [marker(for: plugin)]
        if let reference = referenceContext?.trimmingCharacters(in: .whitespacesAndNewlines), !reference.isEmpty {
            lines.append("")
            lines.append(reference)
        }
        return lines.joined(separator: "\n")
    }

    /// A message's stored context, read back: which plugin it was sent
    /// through, and what is left once the mark is taken off. A context that
    /// never carried the mark comes back whole as `remainder`, so the
    /// side-question and reference parsing downstream see exactly what they
    /// would have seen before this mark existed.
    struct Parsed: Equatable, Sendable {
        var plugin: Plugin?
        var remainder: String?
    }

    static func parse(contextContent: String?) -> Parsed {
        // The sources-added mark (`ChatContextAdditions`) and a skill mark
        // (`ChatSkillRequest`) sit above this one and are nobody's business
        // here: skipped, so a stored context that carries them parses exactly
        // as one that does not.
        guard let content = ChatSkillRequest.stripping(contextContent: contextContent), !content.isEmpty else {
            return Parsed(plugin: nil, remainder: nil)
        }
        let firstLineEnd = content.firstIndex(where: \.isNewline) ?? content.endIndex
        let firstLine = String(content[..<firstLineEnd])
        guard let plugin = Plugin.allCases.first(where: { marker(for: $0) == firstLine }) else {
            return Parsed(plugin: nil, remainder: content)
        }
        let rest = String(content[firstLineEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return Parsed(plugin: plugin, remainder: rest.isEmpty ? nil : rest)
    }

    // MARK: - What the model is told

    /// The instruction appended to the learner's turn, outside the reference
    /// wrapper (which tells the model to follow nothing it contains). It names
    /// the mention the learner typed and the tools that answer it, so the model
    /// reads the service rather than the library — the mistake a plain "what's
    /// in Slack" invited on 2026-09-02 and 2026-09-05.
    static func framing(for plugin: Plugin) -> String {
        switch plugin {
        case .slack:
            return """
            The learner addressed this message to @slack: it is a question about Slack. Answer it from Slack itself, read live in this turn — search_slack_messages for something specific, list_slack_channels and then read_slack_channel for what a channel has been discussing, read_slack_thread for a whole thread — not from the library and not from memory. If Slack is not connected or a channel is not enabled, say so and point at Settings → Plugins → Slack.
            """
        case .linear:
            return """
            The learner addressed this message to @linear: it is a question about Linear. Answer it from Linear itself, read live in this turn with the Linear tools — search_linear_issues, list_linear_issues, get_linear_issue, list_linear_teams, list_linear_projects, get_linear_project — not from the library and not from memory. The connection is read-only: report what you find and never offer to change an issue. If Linear is not connected, say so and point at Settings → Plugins → Linear.
            """
        case .github:
            return """
            The learner addressed this message to @github: it is a question about GitHub. Answer it from GitHub itself, read live in this turn with the GitHub tools — list_github_repositories, get_github_repository, list_github_files, read_github_file, search_github_code, list_github_issues, get_github_issue, list_github_pull_requests, get_github_pull_request, list_github_commits — not from the library and not from memory. When this Notebook names a repository, use it unless the learner names another. The connection is read-only. If GitHub is not connected, say so and point at Settings → Plugins → GitHub.
            """
        case .notion:
            return """
            The learner addressed this message to @notion: it is a question about Notion. Answer it from Notion itself, read live in this turn with the Notion tools — search_notion, get_notion_page, list_notion_databases, get_notion_database, query_notion_database — not from the library and not from memory. Only pages and databases the learner shared with the ForeverLM connection are visible; if what they ask about is not found, say so and tell them a page is shared from its ••• → Connections menu in Notion. The connection is read-only: report what you find and never offer to change a page. If Notion is not connected, say so and point at Settings → Plugins → Notion.
            """
        }
    }

    // MARK: - What a failed read asks the learner to set up

    /// A plugin read that failed because the plugin was not there to read
    /// with: no account connected, the GitHub App not installed where the
    /// repository lives, a grant the service no longer honours, or a Mac that
    /// is not signed in. The chat draws it as a card under the failed step
    /// that opens the plugin's Settings page, so the learner connects the
    /// service where it is connected — not in the Browser.
    ///
    /// The product owner (2026-09-14), after a chat asked to change a site published
    /// from a private repository opened github.com in the Browser, met
    /// GitHub's sign-in page and asked him to sign in there: "it should ask to
    /// set up the github connector … make sure you have those kinds of cards
    /// in the chat". The plugin already reads GitHub as the learner; a
    /// connection that is missing is made in Settings → Plugins, and the card
    /// is the chat's way of saying so.
    struct SetupNeed: Equatable, Hashable, Sendable {
        enum Kind: Equatable, Hashable, Sendable {
            /// No account or workspace is connected to the ForeverLM account.
            case connect
            /// GitHub only: an account is connected, but the ForeverLM App is
            /// not installed on the organisation or account that owns the
            /// repository, so it is out of reach.
            case installOrganisation
            /// The service no longer honours the grant; connect it again.
            case reconnect
            /// This Mac is not signed in with Apple, so there is nothing to
            /// read with.
            case signIn
        }

        var plugin: Plugin
        var kind: Kind
    }

    /// The plugin a tool reads, by its name: every GitHub tool carries
    /// `github`, and so on. `save_site` reads GitHub only when it is given a
    /// repository, so it counts when the failure mentions GitHub.
    static func plugin(forToolName toolName: String, error: String = "") -> Plugin? {
        let name = toolName.lowercased()
        for plugin in Plugin.allCases where name.contains(plugin.rawValue) {
            return plugin
        }
        if name == "save_site", error.lowercased().contains("github") { return .github }
        return nil
    }

    /// What a tool's failure asks the learner to set up, or nil when the
    /// failure is something else — a bad argument, a repository that does not
    /// exist, a channel that is not enabled. Matches the sentences the
    /// gateway and the Mac twins return, which are written for the learner
    /// and passed through as the tool error verbatim.
    static func setupNeed(toolName: String, error: String) -> SetupNeed? {
        guard let plugin = plugin(forToolName: toolName, error: error) else { return nil }
        let text = error.lowercased()
        if text.contains("sign in with apple") {
            return SetupNeed(plugin: plugin, kind: .signIn)
        }
        if text.contains("reconnect") || text.contains("no longer valid") || text.contains("no longer honours") {
            return SetupNeed(plugin: plugin, kind: .reconnect)
        }
        if plugin == .github, text.contains("app is not installed") {
            return SetupNeed(plugin: plugin, kind: .installOrganisation)
        }
        if text.contains("is not connected") || text.contains("not connected")
            || (text.contains("no ") && text.contains(" is connected to this foreverlm account")) {
            return SetupNeed(plugin: plugin, kind: .connect)
        }
        return nil
    }

    /// The needs a turn's failed steps add up to, one per plugin — a chat that
    /// tried three GitHub reads against a missing connection gets one card,
    /// not three — in the order the plugins were first missed, with the last
    /// failure's kind, which is the most recent word on the connection.
    static func setupNeeds(in steps: [(toolName: String, error: String?)]) -> [SetupNeed] {
        var needs: [SetupNeed] = []
        for step in steps {
            guard let error = step.error, let need = setupNeed(toolName: step.toolName, error: error) else { continue }
            if let index = needs.firstIndex(where: { $0.plugin == need.plugin }) {
                needs[index] = need
            } else {
                needs.append(need)
            }
        }
        return needs
    }

    // MARK: - The mention in the composer

    /// `@slack`, `@linear`, `@github`, `@notion` as typed into the composer, the way
    /// Claude's composer takes an `@` for a plugin. Pure text rules, shared
    /// by the popup that offers the mention, the composer that paints it and
    /// the send that reads it off, so the three never disagree about what
    /// counts as one.
    ///
    /// A mention is an `@` at the start of a word — the start of the text or
    /// after whitespace — followed by a plugin's name and then the end of
    /// the text, whitespace or punctuation. `zara@slack.com` is an address,
    /// not a mention; `@slack,` and `@slack:` are mentions.
    enum Mention {
        static let sigil: Character = "@"

        /// A character a plugin's name is made of. Names are lowercase
        /// ASCII; the learner may type them in any case.
        static func isNameCharacter(_ character: Character) -> Bool {
            character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "-")
        }

        /// The `@` token being typed at the very end of `text` — its name so
        /// far, lowercased, possibly empty right after the `@` — with the range
        /// the completion replaces. `nil` once a space follows the name: the
        /// mention is complete and the popup has nothing left to offer.
        static func pendingToken(in text: String) -> (name: String, range: Range<String.Index>)? {
            guard let last = text.last, !last.isWhitespace else { return nil }
            var start = text.endIndex
            while start > text.startIndex {
                let before = text.index(before: start)
                if text[before].isWhitespace { break }
                start = before
            }
            guard text[start] == sigil else { return nil }
            let name = text[text.index(after: start)...]
            guard name.allSatisfy(isNameCharacter) else { return nil }
            return (name.lowercased(), start..<text.endIndex)
        }

        /// The first mention of one of `plugins` in `text`, with its range,
        /// or `nil`. Only a connected plugin is offered, so a name the
        /// gateway does not report connected is ordinary text.
        static func first(
            in text: String,
            plugins: [Plugin]
        ) -> (plugin: Plugin, range: Range<String.Index>)? {
            guard !plugins.isEmpty else { return nil }
            var index = text.startIndex
            while index < text.endIndex {
                let atWordStart = index == text.startIndex || text[text.index(before: index)].isWhitespace
                if text[index] == sigil, atWordStart {
                    var end = text.index(after: index)
                    while end < text.endIndex, isNameCharacter(text[end]) {
                        end = text.index(after: end)
                    }
                    let name = text[text.index(after: index)..<end].lowercased()
                    if let plugin = plugins.first(where: { $0.rawValue == name }) {
                        return (plugin, index..<end)
                    }
                    index = end
                } else {
                    index = text.index(after: index)
                }
            }
            return nil
        }

        /// `text` with the mention at `range` taken out and the whitespace
        /// around the gap closed up, trimmed. Empty when the mention was all
        /// there was — the learner asked the plugin's default question.
        static func removing(_ range: Range<String.Index>, from text: String) -> String {
            var result = text
            result.removeSubrange(range)
            return result
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
        }

        /// The composer text once `plugin` is accepted for the pending token
        /// in `text`: the token replaced by the mention and a space, so typing
        /// resumes after it. `text` unchanged when nothing is pending.
        static func completing(_ text: String, with plugin: Plugin) -> String {
            guard let pending = pendingToken(in: text) else { return text }
            return text[..<pending.range.lowerBound] + "\(sigil)\(plugin.rawValue) "
        }

        /// The plugins the pending token could become, in the order given:
        /// every one right after a bare `@`, narrowed by prefix as the name is
        /// typed. Empty when nothing is pending.
        static func candidates(in text: String, plugins: [Plugin]) -> [Plugin] {
            guard let pending = pendingToken(in: text) else { return [] }
            return plugins.filter { $0.rawValue.hasPrefix(pending.name) }
        }
    }
}
