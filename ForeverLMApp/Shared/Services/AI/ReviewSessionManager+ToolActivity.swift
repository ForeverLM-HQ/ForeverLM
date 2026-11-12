// Part of ReviewSessionManager: tool activity rows and leaked tool text clean-up.

import Foundation

extension ReviewSessionManager {
    /// "#acme-nexus · 30 days" — the channel, and the window when the call set
    /// one. A channel id is an implementation handle and never stands in for
    /// the name: with no name known yet the row keeps its title alone until the
    /// read completes and brings the name with it.
    static func slackChannelDetail(name: String?, arguments: [String: Any]) -> String? {
        let sinceDays: Int?
        if let days = arguments["since_days"] as? Int {
            sinceDays = days
        } else if let days = arguments["since_days"] as? Double {
            sinceDays = Int(days)
        } else if let text = nonEmptyTrimmed(arguments["since_days"] as? String) {
            sinceDays = Int(text)
        } else {
            sinceDays = nil
        }
        return slackChannelDetail(name: name, sinceDays: sinceDays)
    }

    static func slackChannelDetail(name: String?, sinceDays: Int?) -> String? {
        guard let name = nonEmptyTrimmed(name) else { return nil }
        let channel = name.hasPrefix("#") ? name : "#\(name)"
        guard let sinceDays, sinceDays > 0 else { return channel }
        return "\(channel) · \(sinceDays) day\(sinceDays == 1 ? "" : "s")"
    }

    /// Channel names by id from a `list_slack_channels` result. Unnamed
    /// channels (a lookup Slack refused) are skipped rather than mapped to nil.
    static func slackChannelNames(inListResult result: String) -> [String: String] {
        guard let object = jsonObject(result),
              let channels = object["channels"] as? [[String: Any]] else { return [:] }
        var names: [String: String] = [:]
        for channel in channels {
            guard let id = nonEmptyTrimmed(channel["channel_id"] as? String),
                  let name = nonEmptyTrimmed(channel["name"] as? String) else { continue }
            names[id] = name
        }
        return names
    }

    static func slackChannelName(inReadResult result: String) -> String? {
        nonEmptyTrimmed(jsonObject(result)?["channel_name"] as? String)
    }

    static func slackSinceDays(inReadResult result: String) -> Int? {
        guard let value = jsonObject(result)?["since_days"] else { return nil }
        if let days = value as? Int { return days }
        if let days = value as? Double { return Int(days) }
        return nil
    }

    static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static let thinkingActivityName = "thinking"

    /// Fold the attempt's reasoning into the transcript as a `.thinking` row
    /// just above its reply. The first call writes the row and fixes how long
    /// the step thought; later calls only bring the text up to date, since the
    /// reasoning's last publish can land after the answer's first words. No
    /// reasoning, or no reply left to sit above, writes nothing.
    func settleThinking(before anchorMessageID: UUID, reasoning: String, startedAt: Date) {
        let reasoning = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reasoning.isEmpty else { return }
        if let rowID = streamingThinkingRowID,
           let index = chatMessages.firstIndex(where: { $0.id == rowID }),
           var activity = chatMessages[index].toolActivity {
            guard activity.reasoning != reasoning else { return }
            activity.reasoning = reasoning
            chatMessages[index].toolActivity = activity
            return
        }
        guard let anchorIndex = chatMessages.firstIndex(where: { $0.id == anchorMessageID }) else { return }
        let message = Message(
            role: .tool,
            content: "",
            toolActivity: Message.ToolActivity(
                kind: .thinking,
                toolName: Self.thinkingActivityName,
                state: .succeeded,
                reasoning: reasoning,
                thinkingDuration: Date().timeIntervalSince(startedAt)
            )
        )
        chatMessages.insert(message, at: anchorIndex)
        streamingThinkingRowID = message.id
    }

    /// Append a harness-operation row — a context compaction, a stream retry, a
    /// continuation — so maintenance is visible in the transcript the same way
    /// tool calls are, rather than reading as an unexplained pause.
    /// `anchorMessageID` inserts the row above the streaming assistant bubble so
    /// chips read in causal order: user message → operation → reply.
    @discardableResult
    func appendSystemActivity(
        _ kind: Message.ToolActivity.Kind,
        slug: String,
        title: String,
        detail: String? = nil,
        state: Message.ToolActivity.State = .succeeded,
        resultPreview: String? = nil,
        before anchorMessageID: UUID? = nil
    ) -> UUID {
        let message = Message(
            role: .tool,
            content: "",
            toolActivity: Message.ToolActivity(
                kind: kind,
                toolName: slug,
                detail: detail,
                state: state,
                resultPreview: resultPreview.map { String($0.prefix(1_200)) },
                customTitle: title
            )
        )
        if let anchorMessageID,
           let index = chatMessages.firstIndex(where: { $0.id == anchorMessageID }) {
            chatMessages.insert(message, at: index)
        } else {
            chatMessages.append(message)
        }
        return message.id
    }

    /// "84k" / "1.2M" formatting for character counts in harness-row details.
    private static func compactCharacterCountText(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.0fk", Double(count) / 1_000) }
        return "\(count)"
    }

    /// Compact, human-readable rendering of a tool's arguments for the transcript row.
    /// Prefers the argument a reader actually cares about (the query, the topic, the id)
    /// and falls back to a short key list rather than dumping raw JSON.
    static func toolActivityDetail(
        toolName: String,
        arguments: [String: Any]
    ) -> String? {
        // Retrieval queries are model-authored search instructions, not source
        // titles or learner-facing prose. Keep them available to retrieval but
        // do not render them as an ambiguous subtitle in the conversation.
        guard toolName != "retrieve_sources" else { return nil }
        // Slack reads are labelled from the channel-name cache and the read's
        // own result; the arguments hold only an id, which is never a label.
        // A search row shows its query, which `toolArgumentSummary` picks up.
        guard toolName != "read_slack_channel", toolName != "read_slack_thread" else { return nil }
        if toolName == "fetch_web_page" {
            return webPageDetail(arguments["url"] as? String)
        }
        if toolName == ChatCode.toolName {
            return ChatCode.activityDetail(arguments: arguments)
        }
        if ChatBrowsing.isBrowserTool(toolName) {
            let detail = ChatBrowsing.activityDetail(toolName: toolName, arguments: arguments)
            return toolName == "browser_open" ? webPageDetail(detail) : detail
        }
        return toolArgumentSummary(arguments)
    }

    /// A page row reads as its site and path, not a 200-character tracking URL.
    static func webPageDetail(_ rawURL: String?) -> String? {
        guard let rawURL = nonEmptyTrimmed(rawURL) else { return nil }
        guard let url = URL(string: rawURL), let host = url.host else { return rawURL }
        let path = url.path == "/" ? "" : url.path
        let detail = host.replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression) + path
        return detail.count > 72 ? String(detail.prefix(69)) + "…" : detail
    }

    // Review starters return a model-control payload: session bookkeeping,
    // private rubrics, source context, and instructions for conducting the
    // review. The native tool turn still receives that payload verbatim; it is
    // not learner-facing output and must not make the activity chip expandable.
    private static let modelOnlyReviewResultTools: Set<String> = [
        "start_review_session",
        "daily_review",
        "daily_quiz",
        "memory_review",
    ]

    /// Keep operational metadata available to the model while presenting only
    /// the useful retrieval result in the learner's expandable transcript row.
    static func toolResultPreview(toolName: String, result: String) -> String {
        // Failures bypass this helper and remain visible to the learner.
        guard !modelOnlyReviewResultTools.contains(toolName) else { return "" }
        guard toolName != "get_source_content" else { return "" }
        if toolName == "list_sources" {
            return result.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        }
        guard toolName == "retrieve_sources" else { return result }
        return result
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("Query:") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One `## Title (type, id: …)` block of a retrieval result, reduced to what
    /// a reader wants from it.
    struct ParsedRetrievalBlock: Equatable {
        let sourceID: String
        let title: String
        let sourceType: String
        let addedByForeverLM: Bool
        let passage: String
    }

    /// The header line `## Title (type, id: src_…)` the retrieval result gives
    /// every source block, taken apart. The title may itself contain
    /// parentheses, so the id is read from the end and the type from the last
    /// bracket before it.
    nonisolated static func parsedRetrievalHeader(_ line: String) -> (title: String, sourceType: String, sourceID: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("## "), trimmed.hasSuffix(")"),
              let idMarker = trimmed.range(of: ", id: ", options: .backwards) else { return nil }
        let sourceID = String(trimmed[idMarker.upperBound..<trimmed.index(before: trimmed.endIndex)])
            .trimmingCharacters(in: .whitespaces)
        let head = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 3)..<idMarker.lowerBound]
        guard let typeMarker = head.range(of: " (", options: .backwards) else { return nil }
        let title = head[..<typeMarker.lowerBound].trimmingCharacters(in: .whitespaces)
        let sourceType = head[typeMarker.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !sourceID.isEmpty, !title.isEmpty, !sourceType.isEmpty,
              sourceType.allSatisfy({ $0.isLetter }) else { return nil }
        return (title, sourceType, sourceID)
    }

    /// Split a `retrieve_sources` result into per-source blocks, dropping the
    /// lines written for the model: the retrieval reason, the query, the
    /// cross-check warning, paging progress, and every bracketed instruction
    /// note. Bodies come back as readable paragraphs; see `readablePassage`.
    /// A result without a recognisable header yields no blocks, so the row
    /// falls back to its raw preview rather than showing nothing.
    nonisolated static func parsedRetrievalBlocks(from result: String) -> [ParsedRetrievalBlock] {
        result.components(separatedBy: sourceBlockSeparator).compactMap { block in
            var lines = block
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n")
            guard let first = lines.first, let header = parsedRetrievalHeader(first) else { return nil }
            lines.removeFirst()

            var addedByForeverLM = false
            let metadataPrefixes = ["Retrieval reason:", "Query:", "Full-source page:"]
            lines.removeAll { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("Added by ForeverLM:") {
                    addedByForeverLM = true
                    return true
                }
                return metadataPrefixes.contains { trimmed.hasPrefix($0) }
            }

            return ParsedRetrievalBlock(
                sourceID: header.sourceID,
                title: header.title,
                sourceType: header.sourceType,
                addedByForeverLM: addedByForeverLM,
                passage: readablePassage(lines.joined(separator: "\n"))
            )
        }
    }

    /// Turn extracted source text into paragraphs a person can read. PDF text
    /// arrives hard-wrapped at the page's column width, so a line that runs
    /// nearly as long as its paragraph's longest line — or one whose successor
    /// starts in lowercase — is a wrapped line and is joined to the next with
    /// a space. Short lines (headings such as "ABSTRACT", list items, the last
    /// line of a paragraph) keep their break. Bracketed notes are the tutor's
    /// instructions and are removed whole.
    nonisolated static func readablePassage(_ text: String) -> String {
        let paragraphs = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { !($0.hasPrefix("[") && $0.hasSuffix("]")) }

        return paragraphs.map { paragraph -> String in
            let lines = paragraph
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard lines.count > 1 else { return lines.first ?? "" }
            let longest = lines.map(\.count).max() ?? 0
            var output = ""
            for (index, line) in lines.enumerated() {
                if index == 0 {
                    output = line
                    continue
                }
                let previous = lines[index - 1]
                let startsLowercase = line.first.map { $0.isLowercase } ?? false
                let previousIsWrapped = previous.count >= Int(Double(longest) * 0.7)
                    && !looksLikeStructuralLine(previous)
                let joins = !looksLikeStructuralLine(line)
                    && (startsLowercase || previousIsWrapped)
                if joins {
                    output += previous.hasSuffix("-") ? line : " " + line
                } else {
                    output += "\n" + line
                }
            }
            return output
        }.joined(separator: "\n\n")
    }

    /// A heading, list item, or table-like line that must stay on its own line.
    private nonisolated static func looksLikeStructuralLine(_ line: String) -> Bool {
        if line.hasPrefix("#") || line.hasPrefix("- ") || line.hasPrefix("• ") || line.hasPrefix("* ") {
            return true
        }
        if line.range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil { return true }
        // "ABSTRACT", "1. INTRODUCTION": short all-caps section labels.
        let letters = line.filter(\.isLetter)
        return !letters.isEmpty && letters.count <= 40 && letters.allSatisfy(\.isUppercase)
    }

    static func toolArgumentSummary(_ arguments: [String: Any]) -> String? {
        // Record ids are implementation handles, never user-facing labels —
        // neither as a value nor as a key name. Source- and Notebook-specific
        // rows are enriched asynchronously with the record's own title.
        for key in ["query", "topic", "title", "date", "prompt"] {
            if let value = nonEmptyTrimmed(arguments[key] as? String) {
                return value
            }
        }
        return toolFilterSummary(arguments)
    }

    /// What a call with no query text is actually looking for.
    ///
    /// A relative-date request ("what was last week's session on?") reaches the
    /// tools as filters and an empty query, so the row has nothing to quote. A
    /// fallback listing the argument *names* is worse than
    /// silence: "added_from, added_to, limit, query, source_type, threshold"
    /// describes the schema, not the lookup. Say what was filtered on, or say
    /// nothing and let the row's own title carry it.
    private static func toolFilterSummary(_ arguments: [String: Any]) -> String? {
        var parts: [String] = []
        if let sourceType = nonEmptyTrimmed(arguments["source_type"] as? String) {
            parts.append(sourceType)
        }
        switch (
            nonEmptyTrimmed(arguments["added_from"] as? String ?? arguments["date_from"] as? String),
            nonEmptyTrimmed(arguments["added_to"] as? String ?? arguments["date_to"] as? String)
        ) {
        case let (from?, to?):
            parts.append(from == to ? from : "\(from) – \(to)")
        case let (from?, nil):
            parts.append("since \(from)")
        case let (nil, to?):
            parts.append("up to \(to)")
        case (nil, nil):
            break
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    func appendAppToolResult(toolName: String, result: String) {
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = """
        Tool: \(toolName)
        Result:
        \(trimmed.isEmpty ? "(empty result)" : trimmed)
        """
        appToolResultContext = appToolResultContext.isEmpty
            ? entry
            : appToolResultContext + toolResultEntrySeparator + entry
    }

    /// The text-protocol fallback carries tool output in the volatile system
    /// tail. Keep it verbatim until the assembled request actually exceeds the
    /// selected model's input window, then drop older entries first so the
    /// newest lookup (usually the paper the model just requested) stays whole.
    func compactAppToolResultsIfNeeded(config: AITaskConfig, isFirst: Bool) {
        guard !appToolResultContext.isEmpty else { return }

        let system = systemPromptForGeneration(allowSourceRetrieval: true)
        let payload = chatPayload(isFirst: isFirst, systemPrompt: system)
        let messageCharacters = payload.messages.reduce(0) { $0 + $1.content.count + 16 }
        let projectedRequest = payload.system.combined.count + messageCharacters
        guard let inputBudget = AIService.inputCharacterBudget(
            provider: config.provider,
            model: config.model,
            requestedMaxTokens: chatResponseMaxOutputTokens
        ), projectedRequest > inputBudget else { return }

        let original = appToolResultContext
        let availableForResults = max(
            0,
            original.count - (projectedRequest - inputBudget)
        )
        appToolResultContext = trimmedToolResultEntries(
            original,
            budget: availableForResults
        )
        appendSystemActivity(
            .compaction,
            slug: "trim_tool_results",
            title: "Trimmed earlier tool results",
            detail: "\(Self.compactCharacterCountText(original.count)) → \(Self.compactCharacterCountText(appToolResultContext.count)) characters — the full request exceeded this model's context window",
            state: .succeeded
        )
    }

    /// Keep the most recent whole tool-result entries within the budget, dropping
    /// the oldest. If even the newest result cannot fit, retain its beginning so
    /// its tool name, source title, revision, and opening content survive.
    func trimmedToolResultEntries(_ context: String, budget: Int) -> String {
        guard budget > 0 else { return "" }
        let omissionNote = "[Earlier tool results dropped because the complete request exceeded this model's context window.]"
        guard budget > omissionNote.count else {
            return String(omissionNote.prefix(budget))
        }

        let prefix = omissionNote + toolResultEntrySeparator
        var kept: [String] = []
        var remaining = budget - prefix.count
        for entry in context.components(separatedBy: toolResultEntrySeparator).reversed() {
            let cost = entry.count + (kept.isEmpty ? 0 : toolResultEntrySeparator.count)
            if cost <= remaining {
                kept.append(entry)
                remaining -= cost
            } else if kept.isEmpty {
                kept.append(String(entry.prefix(max(0, remaining))))
                break
            } else {
                break
            }
        }
        return prefix + kept.reversed().joined(separator: toolResultEntrySeparator)
    }

    /// Remove a trailing fragment that is a strict prefix of "<flm_tool_call>"
    /// so a tool-call tag never flickers into the bubble while it streams in.
    /// Complete (or unterminated-but-opened) blocks are handled by
    /// `removeToolCallBlocks`; this covers the few frames before the opening tag
    /// has fully arrived. Streaming-display only — never applied to final text.
    static func strippingTrailingPartialToolCallTag(_ text: String) -> String {
        let tag = "<flm_tool_call>"
        guard let lastOpen = text.lastIndex(of: "<") else { return text }
        let suffix = text[lastOpen...]
        guard suffix.count < tag.count, tag.hasPrefix(suffix) else { return text }
        return String(text[..<lastOpen])
    }

    /// Some models leak the bare name of the tool they are about to call into the
    /// visible text channel right before the structured call (seen with several
    /// OpenRouter-hosted models). That debris would otherwise freeze into the
    /// transcript as an assistant message reading "start_review_session". Drop any
    /// line whose content is nothing but called-tool names and punctuation.
    static func strippingLeakedToolNameLines(_ text: String, toolNames: [String]) -> String {
        let names = Set(toolNames.filter { !$0.isEmpty })
        guard !names.isEmpty, !text.isEmpty else { return text }
        let filler = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
        let kept = text.components(separatedBy: .newlines).filter { line in
            var stripped = line
            for name in names {
                stripped = stripped.replacingOccurrences(of: name, with: "")
            }
            guard stripped != line else { return true }
            return !stripped.unicodeScalars.allSatisfy { filler.contains($0) }
        }
        return kept.joined(separator: "\n")
    }

    /// A few routed models duplicate native function arguments into their text
    /// channel while also issuing the real structured call. The tool protocol's
    /// exact argument bytes are authoritative, so remove only an exact duplicate;
    /// arbitrary JSON in an ordinary answer remains untouched.
    static func strippingLeakedNativeToolPayloads(
        _ text: String,
        toolCalls: [AIToolCallRequest]
    ) -> String {
        var cleaned = strippingLeakedToolNameLines(text, toolNames: toolCalls.map(\.name))
        for call in toolCalls {
            let arguments = call.argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !arguments.isEmpty, arguments != "{}" else { continue }
            cleaned = cleaned.replacingOccurrences(of: arguments, with: "")
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A reply with each `【Title】` citation written as the source's link, or as
    /// plain words when no source of this chat has that title, and each source
    /// id it printed as text made that source's link. Some open models cite
    /// that way whatever the prompt says (`ChatSourceTitleIndex`,
    /// `ChatSourceIDCitations`).
    func repairingSourceTitleMarkers(in text: String) -> String {
        guard text.contains("\u{3010}") || text.range(of: "src_", options: .caseInsensitive) != nil else { return text }
        var index = toolSourceTitles
        for article in activeArticles { index.note(id: article.id, title: article.title) }
        for found in foundSources { index.note(id: found.id, title: found.title) }
        return ChatSourceIDCitations.linking(index.repairing(text), titleByID: index.titleByID)
    }

    static func visibleAssistantText(from text: String) -> String? {
        // The suggested-questions tail is hidden as it streams, and from any
        // reply that still carries it.
        let withoutToolCalls = ChatFollowUps.hidingBlock(in: removeToolCallBlocks(from: text))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !withoutToolCalls.isEmpty else { return nil }
        return withoutToolCalls
    }

    private static func removeToolCallBlocks(from text: String) -> String {
        // Runs on every message of the transcript each time a streamed token
        // lands, so the common case — prose with no tag at all — has to be a
        // memchr over the bytes, not Foundation's option-aware substring
        // search; `utf8.contains` goes through the generic iterator and was
        // nearly as slow.
        guard ChatFollowUps.containsAngleBracket(text) else { return text }
        let startTag = "<flm_tool_call>"
        let endTag = "</flm_tool_call>"
        var remaining = text
        while let start = remaining.range(of: startTag) {
            guard let end = remaining.range(of: endTag, range: start.upperBound..<remaining.endIndex) else {
                remaining.removeSubrange(start.lowerBound..<remaining.endIndex)
                break
            }
            remaining.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return remaining
    }
}
