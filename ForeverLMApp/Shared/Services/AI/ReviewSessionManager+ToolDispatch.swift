// Part of ReviewSessionManager: parsing and running app tool calls.

import Foundation
import Observation
import PDFKit
import os

extension ReviewSessionManager {
    func parseSynthesisToolCall(_ response: String) -> SynthesisToolCall? {
        guard let object = toolCallObject(from: response),
              let tool = object["tool"] as? String,
              let markdown = object["markdown"] as? String else {
            return nil
        }
        let action: SynthesisToolCall.Action
        switch tool {
        case "add_to_synthesis":
            action = .append
        case "replace_synthesis":
            action = .replace
        default:
            return nil
        }
        let cleanMarkdown = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanMarkdown.isEmpty else { return nil }
        return SynthesisToolCall(action: action, markdown: cleanMarkdown)
    }

    func parseAppToolCall(_ response: String) -> AppToolCall? {
        guard let object = toolCallObject(from: response),
              object["tool"] as? String == "foreverlm_tool",
              let name = object["name"] as? String else {
            return nil
        }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return nil }
        let arguments = object["arguments"] as? [String: Any] ?? [:]
        return AppToolCall(name: cleanName, arguments: arguments)
    }

    /// Run one app tool call with a watchdog. Returns the tool's own result, a
    /// timeout error result if the watchdog fires first, or throws
    /// CancellationError promptly when Stop cancels the turn mid-call.
    func executeAppToolCall(_ call: AppToolCall) async throws -> AppToolResult {
        guard let appToolExecutor else {
            return AppToolResult(
                text: "ForeverLM app tools are not available in this Chat surface.",
                isError: true
            )
        }
        // A tool that checks what it saves does so on the model this chat is
        // on (`ChatRequestedModel`), not on a background task's own route.
        if let sessionID, ChatRequestedModel.toolNames.contains(call.name) {
            let resolved: AITaskConfig?
            if let modelOverride {
                resolved = modelOverride
            } else {
                resolved = await Self.resolveChatConfig().config
            }
            ChatRequestedModel.set(resolved, forSession: sessionID)
        }
        defer { if let sessionID { ChatRequestedModel.set(nil, forSession: sessionID) } }
        let result = try await Self.runAppToolCall(
            name: call.name,
            arguments: notebookScopedArguments(toolName: call.name, arguments: call.arguments),
            hostSessionID: sessionID,
            watchdogSeconds: appToolCallWatchdogSeconds,
            executor: appToolExecutor
        )
        // Cards this chat saved are drawn in the transcript as the cards
        // (`ChatSavedCards`), so the model is told it need not list them.
        if call.name == "save_card_drafts", !result.isError {
            return AppToolResult(text: ChatSavedCards.notingShownInChat(result.text), isError: false)
        }
        if call.name == "create_notebook", !result.isError {
            await followNotebookThisChatMade()
        }
        return result
    }

    /// A Notebook this chat made took the chat in (`create_notebook` files the
    /// chat that called it), so the chat follows: its scope becomes the
    /// Notebook's for the rest of the turn, and its window opens the Notebook
    /// with this chat in it (product owner, 2026-10-11: "it should JUST open
    /// that notebook and move the chat to there"). Read back from the chat's
    /// record rather than the tool's words, so a Notebook made without
    /// taking the chat in moves nothing.
    private func followNotebookThisChatMade() async {
        guard let sessionID,
              let notebookID = try? await storage.loadReviewSessionGoalID(sessionID: sessionID),
              notebookID != notebookSourceScopeID else { return }
        // `create_notebook` filed the Pages the chat's stored replies carry;
        // those this turn wrote before it wait for the reply, so they are
        // filed here. Missing one leaves a Page in no Notebook, as before.
        let turnPageIDs = stagedWrittenPages.map(\.id)
        if !turnPageIDs.isEmpty {
            do {
                try await storage.fileChatPages(sessionID: sessionID, pageIDs: turnPageIDs, inNotebook: notebookID)
            } catch {
                logger.error("Filing this turn's Pages in the Notebook it made failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        setNotebookScope(notebookID)
        await notebookWithThisChatOpener?(notebookID, sessionID)
    }

    /// The tool, the watchdog or Stop, whichever comes first, and nothing
    /// waits for the tool to notice it lost. The task group this replaced
    /// did: a group returns only once every child has, so a tool that took
    /// no notice of the cancel held Stop, and the watchdog, for as long as it
    /// ran. A tool left behind is cancelled and winds down on its own.
    static func runAppToolCall(
        name: String,
        arguments: [String: Any],
        hostSessionID: String?,
        watchdogSeconds: TimeInterval,
        executor: @escaping (String, [String: Any], String?) async -> AppToolResult
    ) async throws -> AppToolResult {
        try await CancellableWait.run(
            timeout: watchdogSeconds,
            timedOut: {
                AppToolResult(
                    text: "Error: The \(name) tool call timed out after \(Int(watchdogSeconds)) seconds and was abandoned. The operation may still finish in the background — re-check the relevant app state before retrying it.",
                    isError: true
                )
            }
        ) {
            await executor(name, arguments, hostSessionID)
        }
    }

    /// True when a tool-less reply reads as a promise to do more work rather than a
    /// delivered answer — e.g. "searching your library now", "let me look for sources".
    /// Only the tail is inspected because a forward-looking promise lands at the end of
    /// the reply; a past-tense mention mid-answer ("I searched for X and found…") is fine.
    func replyPromisesUncalledToolWork(_ response: String) -> Bool {
        let trimmed = Self.normalizedApostrophes(in: response)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !trimmed.isEmpty else { return false }
        let tail = String(trimmed.suffix(220))
        let promissoryCues = [
            "searching now", "searching your library", "searching the library",
            "scanning your library", "scanning the library", "scanning now",
            "let me search", "let me look", "let me find", "let me pull",
            "let me grab", "let me fetch", "let me retrieve", "let me check",
            "i'll search", "i will search", "i'll look", "i will look",
            "i'll find", "i will find", "i'll pull", "i will pull",
            "i'll grab", "i will grab", "i'll fetch", "i will fetch",
            "i'll retrieve", "i will retrieve", "i'll check", "i will check",
            "now searching", "now scanning", "now finding", "now looking",
            "finding all", "finding sources", "looking for sources",
            "pulling up", "content now", "sources now", "one moment",
            "give me a moment", "hold on", "on it now"
        ]
        return promissoryCues.contains { tail.contains($0) }
    }

    /// Fold the typographic apostrophes models actually emit onto the ASCII one.
    /// Cue matching that only knew `'` never saw "I’ll pull the transcript" — the
    /// exact shape of the reply that ends a turn with a promise and no work.
    private static func normalizedApostrophes(in text: String) -> String {
        guard text.contains(where: { "\u{2019}\u{02BC}\u{FF07}\u{2018}`\u{00B4}".contains($0) }) else {
            return text
        }
        return String(text.map { character in
            "\u{2019}\u{02BC}\u{FF07}\u{2018}`\u{00B4}".contains(character) ? "'" : character
        })
    }

    /// A turn that ends holding an <flm_tool_call> the parsers cannot read has
    /// nothing to show for itself: the block is stripped from the visible reply,
    /// so what is left is the model's lead-in. Fail with the reason instead of
    /// presenting that lead-in as the answer.
    func unreadableToolCallError() -> AIError {
        AIError.apiError(
            "The AI kept emitting a tool call this app could not read, so nothing ran and no answer was saved after \(malformedToolCallNudgeMaxAttempts) automatic correction attempts. Please retry, or switch Chat models if it keeps happening."
        )
    }

    /// The identity tokens in a reply's in-app source links. The extractor is
    /// `ChatSourceEvidence`'s, because the memory review reads the same links
    /// back to decide which sources a chat was about.
    static func sourceLinkTokens(in response: String) -> [String] {
        ChatSourceEvidence.sourceLinkTokens(in: response)
    }

    /// Return every citation token that cannot be resolved exactly or as a
    /// unique prefix in the persisted library. Storage failures propagate: a
    /// database error is not equivalent to a missing citation.
    func unresolvedSourceLinkTokens(in response: String) async throws -> [String] {
        var unresolved: [String] = []
        for token in Self.sourceLinkTokens(in: response) {
            if try await storage.resolveSourceID(forLinkToken: token) == nil {
                unresolved.append(token)
            }
        }
        return unresolved
    }

    var invalidSourceLinkCorrectionNudge: String {
        """
        Your previous reply contained one or more ForeverLM source links that do not resolve to real records in the learner's library. Rewrite the complete answer now. Use only exact foreverlm://source/ links returned by an app tool in this conversation. If no tool result supports a source, leave it unlinked and do not invent duplicate records or source IDs. Never show a raw source ID as visible text.
        """
    }

    static var courseQuizNeedsNativeToolsError: AIError {
        AIError.apiError(
            "This chat model cannot call the quiz's grader, so your answer was not graded. Choose another model with the model chip under the message box and send your answer again."
        )
    }

    func invalidSourceLinkError(count: Int) -> AIError {
        AIError.apiError(
            "The AI returned \(count) source link\(count == 1 ? "" : "s") that do not exist in this ForeverLM library after \(invalidSourceLinkNudgeMaxAttempts) automatic correction attempts. The answer was not saved. Please retry."
        )
    }

    /// Every picture address in a reply this device cannot show: a source the
    /// library does not have, a drawn, kept or attached picture this device
    /// does not hold, or a target no picture grammar reads
    /// (`ChatPictureAddress`). Storage failures propagate, as they do for
    /// source links.
    func unresolvedPictureAddresses(in response: String) async throws -> [String] {
        let targets = SourceImageReference.pictureAddresses(in: response)
        guard !targets.isEmpty else { return [] }
        var unresolved: [String] = []
        for target in targets {
            switch ChatPictureAddress(target) {
            case .source(let id):
                if try await storage.resolveSourceID(forLinkToken: id) == nil { unresolved.append(target) }
            case .unreadable:
                unresolved.append(target)
            case .generated, .attached:
                break
            }
        }
        // The store lookup touches the disk: it stays off the main actor.
        let unheld = await Task.detached(priority: .userInitiated) {
            ChatPictureAddress.unheldStoredPictures(in: targets) { address in
                switch address {
                case .generated(let id): return GeneratedImageStore.holds(id: id)
                case .attached(let id): return AttachedImageStore.holds(id: id)
                case .source, .unreadable: return false
                }
            }
        }.value
        return unresolved + unheld
    }

    var invalidPictureAddressCorrectionNudge: String {
        """
        Your previous reply showed one or more ForeverLM pictures (foreverlm://image/ lines) that this device does not have, so the learner would see "picture unavailable" in their place. The learner has not seen that reply. Rewrite the complete answer now. Show a picture only with the exact Markdown image line a tool returned, copied character for character; never write or change an image id yourself, and never copy one from an earlier message. If no such line fits, leave the picture out.
        """
    }

    func invalidPictureAddressError(count: Int) -> AIError {
        AIError.apiError(
            "The AI showed \(count) picture\(count == 1 ? "" : "s") that do not exist after \(invalidPictureAddressNudgeMaxAttempts) automatic correction attempts. The answer was not saved. Please retry, or switch Chat models if it keeps happening."
        )
    }

    /// Add a "running" tool row to the transcript and return its id.
    @discardableResult
    func appendToolActivity(for call: AppToolCall) -> UUID {
        let requestedSourceID = (call.arguments["source_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let immediateSource = requestedSourceID.flatMap(sourcePresentationFromActiveArticles)
        let detail: String?
        if call.name == "read_slack_channel" {
            detail = Self.slackChannelDetail(
                name: Self.requestedSlackChannelID(in: call.arguments).flatMap { slackChannelNames[$0] },
                arguments: call.arguments
            )
        } else if call.name == "read_slack_thread" {
            detail = Self.slackChannelDetail(
                name: Self.requestedSlackChannelID(in: call.arguments).flatMap { slackChannelNames[$0] },
                sinceDays: nil
            )
        } else {
            detail = immediateSource?.title ?? Self.toolActivityDetail(
                toolName: call.name,
                arguments: call.arguments
            )
        }
        let message = Message(
            role: .tool,
            content: "",
            toolActivity: Message.ToolActivity(
                toolName: call.name,
                detail: detail,
                sourcePresentation: immediateSource,
                state: .running,
                resultPreview: nil
            )
        )
        chatMessages.append(message)
        if let requestedSourceID, immediateSource == nil {
            Task { await resolveSourcePresentation(for: message.id, requestedID: requestedSourceID) }
        }
        if message.toolActivity?.detail == nil,
           let requestedNotebookID = Self.requestedNotebookID(in: call.arguments) {
            Task { await resolveNotebookDetail(for: message.id, requestedID: requestedNotebookID) }
        }
        return message.id
    }

    /// The Notebook (learning-goal) record a call names, under either of the two
    /// argument spellings the tools use.
    private static func requestedNotebookID(in arguments: [String: Any]) -> String? {
        for key in ["notebook_id", "goal_id"] {
            if let value = (arguments[key] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// Label a Notebook row with the Notebook's name. The id stays out of the
    /// transcript entirely: a row whose Notebook cannot be resolved keeps its
    /// bare title rather than falling back to the raw identifier.
    private func resolveNotebookDetail(for activityID: UUID, requestedID: String) async {
        guard let goals = try? await storage.loadLearningGoals() else { return }
        let exact = goals.first { $0.id == requestedID }
        let goal: LearningGoalRecord?
        if let exact {
            goal = exact
        } else if requestedID.count >= 8 {
            let matches = goals.filter { $0.id.hasPrefix(requestedID) }
            goal = matches.count == 1 ? matches[0] : nil
        } else {
            goal = nil
        }
        let title = goal?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return }
        guard let index = chatMessages.firstIndex(where: { $0.id == activityID }),
              var activity = chatMessages[index].toolActivity,
              activity.detail == nil else { return }
        activity.detail = title
        chatMessages[index].toolActivity = activity
    }

    func sourcePresentationFromActiveArticles(
        _ requestedID: String
    ) -> Message.ToolActivity.SourcePresentation? {
        let exact = activeArticles.first { $0.id == requestedID }
        let article: StudioArticle?
        if let exact {
            article = exact
        } else if requestedID.count >= 8 {
            let matches = activeArticles.filter { $0.id.hasPrefix(requestedID) }
            article = matches.count == 1 ? matches[0] : nil
        } else {
            article = nil
        }
        guard let article else { return nil }
        return Message.ToolActivity.SourcePresentation(source: article)
    }

    private func resolveSourcePresentation(for activityID: UUID, requestedID: String) async {
        guard let canonicalID = try? await storage.resolveSourceID(forLinkToken: requestedID),
              let article = try? await storage.loadPersistedSources(ids: [canonicalID]).first else { return }
        guard let index = chatMessages.firstIndex(where: { $0.id == activityID }),
              var activity = chatMessages[index].toolActivity else { return }
        let presentation = Message.ToolActivity.SourcePresentation(source: article)
        activity.sourcePresentation = presentation
        activity.detail = presentation.title
        chatMessages[index].toolActivity = activity
    }

    /// Load the records behind a day listing so its row can draw a banner per
    /// source. Ids the library no longer holds are dropped; the raw preview
    /// stays behind the row for the case where none resolve.
    private func resolveListedSources(for activityID: UUID, sourceIDs: [String]) async {
        guard let articles = try? await storage.loadPersistedSources(ids: sourceIDs), !articles.isEmpty else { return }
        let byID = Dictionary(articles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let presentations = sourceIDs.compactMap { byID[$0] }.map(Message.ToolActivity.SourcePresentation.init(source:))
        guard let index = chatMessages.firstIndex(where: { $0.id == activityID }),
              var activity = chatMessages[index].toolActivity else { return }
        activity.listedSources = presentations
        chatMessages[index].toolActivity = activity
    }

    /// What a `get_today_sources` result lists, read off the text the tool
    /// wrote for the model: every `=== source_id: … ===` section header, the
    /// day from its first line, and a row title in the learner's terms —
    /// "What you watched today" rather than "Loaded today's sources" when the
    /// call asked what they watched. Nil title for a planned-day listing,
    /// which keeps the generic phrase.
    nonisolated static func todaySourcesListing(in result: String) -> (title: String?, day: String?, sourceIDs: [String]) {
        let lines = result.components(separatedBy: "\n")
        let sourceIDs = lines.compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("=== source_id: "), trimmed.hasSuffix(" ===") else { return nil }
            let id = trimmed.dropFirst("=== source_id: ".count).dropLast(" ===".count)
                .trimmingCharacters(in: .whitespaces)
            return id.isEmpty ? nil : id
        }
        let heading = lines.first ?? ""
        let isToday = heading.contains(" for today (")
        let day = heading.range(of: "[0-9]{4}-[0-9]{2}-[0-9]{2}", options: .regularExpression).map { String(heading[$0]) }
        let verbs: [(String, String)] = [
            ("Sources used for watching", "What you watched"),
            ("Sources used for reading", "What you read"),
            ("Sources used for listening", "What you listened to"),
            ("Sources used for chat", "Sources you chatted about"),
            ("Sources used for review", "Sources you reviewed"),
            ("Sources used in ForeverLM", "Sources you used"),
            ("Sources completed in ForeverLM", "Sources you finished"),
        ]
        let title = verbs.first { heading.hasPrefix($0.0) }.map { isToday ? "\($0.1) today" : $0.1 }
        return (title, day, sourceIDs)
    }

    /// Takes a page off this turn's cards once a later call of the turn moved
    /// it to the Trash or hid it (`ChatWrittenPage.removedID`): the reply
    /// stores no line for it, and the step that wrote it draws no card.
    private func dropWrittenPage(_ id: String) {
        stagedWrittenPages.removeAll { $0.id == id }
        let start = chatMessages.lastIndex(where: { $0.role == .user }).map { $0 + 1 } ?? 0
        for index in start..<chatMessages.count where chatMessages[index].toolActivity?.writtenPage?.id == id {
            chatMessages[index].toolActivity?.writtenPage = nil
        }
    }

    /// Mark a tool row finished and attach a short preview of what it returned.
    /// Failure comes from the tool layer's own `isError` flag, not message sniffing.
    func completeToolActivity(_ id: UUID, result: AppToolResult) {
        // A tool that failed after Stop cancelled the turn most likely failed
        // of the cancel, and its own words for that ("cancelled", a grader
        // that "could not grade it") read as a fault. The row stays running
        // for the stopped turn to mark (`markRunningToolActivitiesStopped`),
        // whichever tool it was. A tool that finished is still shown finished.
        guard !(result.isError && Task.isCancelled) else { return }
        guard let index = chatMessages.firstIndex(where: { $0.id == id }),
              var activity = chatMessages[index].toolActivity else { return }
        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        activity.state = (result.isError || trimmed.isEmpty) ? .failed : .succeeded
        if activity.state == .failed {
            // The row's own words are not saved with the chat, so a failure
            // seen in a screenshot could not be traced back to its cause
            // (2026-11-10). At error level the line stays in the unified log
            // for hours.
            logger.error("Chat tool \(activity.toolName, privacy: .public) failed: \(String(trimmed.prefix(400)), privacy: .public)")
        }
        if !result.isError {
            toolSourceTitles.harvest(toolResult: trimmed)
            if activity.toolName == "retrieve_sources" {
                for block in Self.parsedRetrievalBlocks(from: trimmed) {
                    toolSourceTitles.note(id: block.sourceID, title: block.title)
                }
            }
        }
        // A successful source read is represented by its compact source card in
        // the transcript. Keep failures expandable so the tool error still
        // surfaces instead of being hidden behind the presentation treatment.
        let preview = result.isError
            ? trimmed
            : Self.toolResultPreview(toolName: activity.toolName, result: trimmed)
        activity.resultPreview = preview.isEmpty ? nil : String(preview.prefix(1_200))
        if !result.isError {
            switch activity.toolName {
            case "retrieve_sources":
                // The learner sees each retrieved source as a card with a readable
                // passage, never the id-bearing header the model is given.
                let passages = Self.parsedRetrievalBlocks(from: trimmed).map { block in
                    Message.ToolActivity.RetrievedPassage(
                        sourceID: block.sourceID,
                        title: block.title,
                        sourceType: block.sourceType,
                        presentation: sourcePresentationFromActiveArticles(block.sourceID),
                        addedByForeverLM: block.addedByForeverLM,
                        passage: block.passage
                    )
                }
                activity.retrievedPassages = passages
                let requested = passages.filter { !$0.addedByForeverLM }
                if requested.count == 1, let only = requested.first {
                    activity.sourcePresentation = only.presentation
                    activity.detail = only.title
                } else if passages.count > 1 {
                    activity.detail = "\(passages.count) sources"
                }
            case "save_card_drafts":
                // The cards are drawn as themselves, and the reply stores
                // them so they are drawn again when the chat is reopened.
                if let saved = ChatSavedCards.parse(toolResult: trimmed) {
                    activity.savedCards = saved
                    activity.detail = saved.label
                    stagedSavedCards = stagedSavedCards.map { $0.merging(saved) } ?? saved
                }
            case _ where ChatWrittenPage.toolNames.contains(activity.toolName):
                // The page is drawn as a card under the reply's work, and the
                // reply stores it so the card comes back when the chat is
                // reopened. The row names the page rather than its id.
                if let page = ChatWrittenPage.parse(toolName: activity.toolName, result: trimmed) {
                    activity.writtenPage = page
                    if !page.title.isEmpty { activity.detail = page.title }
                    stagedWrittenPages = ChatWrittenPage.adding(page, to: stagedWrittenPages)
                } else if let removed = ChatWrittenPage.removedID(toolName: activity.toolName, result: trimmed) {
                    dropWrittenPage(removed)
                }
            case ChatWrittenPage.deleteToolName, ChatWrittenPage.deleteAnimationToolName:
                if let removed = ChatWrittenPage.removedID(toolName: activity.toolName, result: trimmed) {
                    dropWrittenPage(removed)
                }
            case "get_today_sources":
                let listed = Self.todaySourcesListing(in: trimmed)
                if let heading = listed.title {
                    activity.customTitle = heading
                }
                if !listed.sourceIDs.isEmpty {
                    let count = "\(listed.sourceIDs.count) source\(listed.sourceIDs.count == 1 ? "" : "s")"
                    activity.detail = [listed.day, count].compactMap { $0 }.joined(separator: " · ")
                    Task { await resolveListedSources(for: id, sourceIDs: listed.sourceIDs) }
                }
            case "list_slack_channels":
                slackChannelNames.merge(Self.slackChannelNames(inListResult: trimmed)) { _, new in new }
            case "read_slack_channel", "read_slack_thread":
                if let name = Self.slackChannelName(inReadResult: trimmed) {
                    if let channelID = Self.slackChannelID(inReadResult: trimmed) {
                        slackChannelNames[channelID] = name
                    }
                    activity.detail = Self.slackChannelDetail(
                        name: name,
                        sinceDays: activity.toolName == "read_slack_channel" ? Self.slackSinceDays(inReadResult: trimmed) : nil
                    )
                }
            case "search_slack_messages":
                // Hits name their channels; remember them so a follow-up thread
                // read can label its row before its own result arrives.
                for hit in (Self.jsonObject(trimmed)?["messages"] as? [[String: Any]]) ?? [] {
                    if let id = Self.nonEmptyTrimmed(hit["channel_id"] as? String),
                       let name = Self.nonEmptyTrimmed(hit["channel_name"] as? String) {
                        slackChannelNames[id] = name
                    }
                }
            default:
                break
            }
        }
        chatMessages[index].toolActivity = activity
    }

    // MARK: Slack rows

    /// The channel a `read_slack_channel` call names, or nil when the argument
    /// is missing or blank.
    private static func requestedSlackChannelID(in arguments: [String: Any]) -> String? {
        nonEmptyTrimmed(arguments["channel_id"] as? String)
    }

    private static func slackChannelID(inReadResult result: String) -> String? {
        nonEmptyTrimmed(jsonObject(result)?["channel_id"] as? String)
    }
}
