import Foundation

/// A conversation read from the assistant's own record on this Mac rather
/// than retyped by the assistant into a tool argument.
///
/// `import_review_chat` used to receive the chat only as text the assistant
/// composed, and an assistant that called it before writing its answer sent a
/// shortened rendition — the saved chat was a summary of the answer, without
/// the source links the answer carried. The assistant's client already keeps
/// the exact record: Claude Code writes every session to
/// `~/.claude/projects/<project>/<session id>.jsonl` as it goes, with what the
/// learner typed and every text the assistant showed, timestamped. Reading
/// that file makes the stored chat the chat on screen, word for word, and the
/// hours it ran come from the file instead of being declared.
///
/// Two shapes are read. A Claude Code session file is a JSONL stream in which
/// each line is a record with a `type`; the learner's turns are `user` records
/// whose message content is a string or text blocks (tool results are not the
/// learner), messages the learner sent while a turn was running are
/// `attachment` records of type `queued_command`, and the assistant's turns are
/// `assistant` records whose message content holds text blocks beside the tool
/// calls and thinking that are not shown as prose. Anything else — a
/// role-labelled export — goes through `ReviewTranscriptParser` as the
/// `transcript` argument does.
struct AssistantTranscriptFile: Sendable {
    enum Kind: Sendable {
        case claudeCodeSession
        case roleLabelledText
    }

    let kind: Kind
    let messages: [ReviewTranscriptMessage]
    /// The title the learner gave the session in its client, when the record
    /// carries one (Claude Code's `custom-title`).
    let title: String?
    /// The model that wrote the last assistant turn, as the record names it.
    let modelID: String?
    /// When the first learner turn and the last recorded turn happened.
    let startedAt: Date?
    let endedAt: Date?

    var turns: [ReviewChatTurn] {
        ReviewTranscriptParser.turns(from: messages)
    }

    // MARK: - Reading

    enum ReadError: LocalizedError {
        case unreadable(String)
        case empty(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let path):
                return "Could not read the transcript file at \(path)."
            case .empty(let path):
                return "The transcript file at \(path) holds no conversation: no learner message and no assistant text."
            }
        }
    }

    static func read(at url: URL) throws -> AssistantTranscriptFile {
        guard let data = FileManager.default.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8) else {
            throw ReadError.unreadable(url.path)
        }
        let file: AssistantTranscriptFile
        if let session = claudeCodeSession(from: text) {
            file = session
        } else {
            let messages = ReviewTranscriptParser.messages(from: text)
            file = AssistantTranscriptFile(
                kind: .roleLabelledText,
                messages: messages,
                title: nil,
                modelID: nil,
                startedAt: nil,
                endedAt: nil
            )
        }
        guard !file.messages.isEmpty else { throw ReadError.empty(url.path) }
        return file
    }

    /// A Claude Code session id names exactly one file under the notebooks
    /// directory: `~/.claude/projects/<project>/<id>.jsonl`. The notebook
    /// directory is Claude Code's own encoding of the working directory, which
    /// the caller need not reproduce.
    static func claudeCodeSessionFile(id: String, notebooksRoot: URL) -> URL? {
        guard isSessionID(id) else { return nil }
        let fileManager = FileManager.default
        guard let notebooks = try? fileManager.contentsOfDirectory(
            at: notebooksRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for notebook in notebooks.sorted(by: { $0.path < $1.path }) {
            let candidate = notebook.appendingPathComponent("\(id).jsonl")
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    static func isSessionID(_ text: String) -> Bool {
        UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    // MARK: - Claude Code session files

    /// Learner records Claude Code writes as user messages that no one typed:
    /// slash-command echoes, hook output, and task notifications. A message
    /// opening with one of these tags is the harness talking, not the learner.
    private static let harnessTags: [String] = [
        "<command-name>", "<command-message>", "<command-args>",
        "<local-command-stdout>", "<local-command-stderr>", "<local-command-caveat>",
        "<bash-input>", "<bash-stdout>", "<bash-stderr>",
        "<user-prompt-submit-hook>", "<task-notification>", "<ci-monitor-event>",
        "[Request interrupted by user",
    ]

    private static let systemReminderPattern = try! NSRegularExpression(
        pattern: #"<system-reminder>.*?</system-reminder>"#,
        options: [.dotMatchesLineSeparators]
    )

    /// nil when the text is not a Claude Code session file at all — its first
    /// line is not a JSON object with a `type` — so the caller can read it as
    /// prose. A file that is a session yields its messages, possibly none.
    static func claudeCodeSession(from text: String) -> AssistantTranscriptFile? {
        var lines = text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first,
              let firstRecord = jsonObject(first),
              firstRecord["type"] is String else {
            return nil
        }
        lines = lines.filter { $0.hasPrefix("{") }

        var messages: [ReviewTranscriptMessage] = []
        var title: String?
        var modelID: String?
        var seenUUIDs = Set<String>()

        for line in lines {
            guard let record = jsonObject(line), let type = record["type"] as? String else { continue }
            // A sub-agent's transcript is a conversation the learner never
            // saw; only the main thread is the chat.
            if record["isSidechain"] as? Bool == true { continue }
            if let uuid = record["uuid"] as? String {
                if seenUUIDs.contains(uuid) { continue }
                seenUUIDs.insert(uuid)
            }
            let timestamp = (record["timestamp"] as? String).flatMap(parseTimestamp)

            switch type {
            case "custom-title":
                if let custom = (record["customTitle"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
                    title = custom
                }
            case "user":
                if record["isMeta"] as? Bool == true || record["isCompactSummary"] as? Bool == true { continue }
                guard let message = record["message"] as? [String: Any] else { continue }
                if let text = learnerText(from: message["content"]) {
                    appendLearner(text, at: timestamp, to: &messages)
                }
            case "attachment":
                guard let attachment = record["attachment"] as? [String: Any],
                      attachment["type"] as? String == "queued_command",
                      let prompt = attachment["prompt"] as? String else { continue }
                let text = cleanedLearnerText(prompt)
                if let text {
                    let sentAt = (attachment["timestamp"] as? String).flatMap(parseTimestamp) ?? timestamp
                    appendLearner(text, at: sentAt, to: &messages)
                }
            case "assistant":
                guard let message = record["message"] as? [String: Any],
                      let blocks = message["content"] as? [[String: Any]] else { continue }
                let texts = blocks.compactMap { block -> String? in
                    guard block["type"] as? String == "text",
                          let text = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !text.isEmpty else { return nil }
                    return text
                }
                guard !texts.isEmpty else { continue }
                if let model = (message["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !model.isEmpty {
                    modelID = model
                }
                messages.append(ReviewTranscriptMessage(
                    role: .assistant,
                    text: texts.joined(separator: "\n\n"),
                    timestamp: timestamp
                ))
            default:
                continue
            }
        }

        let stamps = messages.compactMap(\.timestamp)
        return AssistantTranscriptFile(
            kind: .claudeCodeSession,
            messages: messages,
            title: title,
            modelID: modelID,
            startedAt: messages.first(where: { $0.role == .learner })?.timestamp ?? stamps.first,
            endedAt: stamps.last
        )
    }

    /// A message the learner sent while a turn ran is logged as a queued
    /// command and, when the turn ends before it is read, again as the next
    /// user message; the same text twice in a row is one message.
    private static func appendLearner(_ text: String, at timestamp: Date?, to messages: inout [ReviewTranscriptMessage]) {
        if let last = messages.last, last.role == .learner, last.text == text { return }
        messages.append(ReviewTranscriptMessage(role: .learner, text: text, timestamp: timestamp))
    }

    private static func learnerText(from content: Any?) -> String? {
        if let text = content as? String {
            return cleanedLearnerText(text)
        }
        guard let blocks = content as? [[String: Any]] else { return nil }
        // Tool results travel in user messages; only text blocks are the learner.
        let texts = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "text", let text = block["text"] as? String else { return nil }
            return cleanedLearnerText(text)
        }
        guard !texts.isEmpty else { return nil }
        return texts.joined(separator: "\n\n")
    }

    /// The learner's words without the context the harness folds into the
    /// same message, and nothing at all when the message was the harness's.
    static func cleanedLearnerText(_ raw: String) -> String? {
        let range = NSRange(raw.startIndex..., in: raw)
        let stripped = systemReminderPattern.stringByReplacingMatches(in: raw, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return nil }
        for tag in harnessTags where stripped.hasPrefix(tag) {
            return nil
        }
        return stripped
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    private static func parseTimestamp(_ text: String) -> Date? {
        MCPDataStore.parseISODate(text)
    }
}
