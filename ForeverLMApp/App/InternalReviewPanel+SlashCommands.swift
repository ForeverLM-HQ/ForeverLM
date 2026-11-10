// Slash commands, mentions and their running in the chat panel.
import SwiftUI
import Combine
import AppKit

extension InternalReviewPanelContent {
    // MARK: - Slash commands

    @MainActor
    func acceptSlashSuggestion(_ suggestion: ReviewSlashSuggestion) {
        slashSelectionIndex = 0
        // A library row is accepted by identity: two sources can share a title,
        // so the id it carries runs the command and the composer is simply cleared.
        if let picked = suggestion.reference {
            draft = ""
            lastInsertedDefaultPrompt = nil
            Task { await runSlashReference(picked.command, reference: picked.reference, title: suggestion.title) }
            return
        }
        // Something an `@` found: the `@` and its query leave the draft, the
        // rest of what was typed stays, and the item comes in by its own path.
        if let item = suggestion.libraryItem {
            draft = suggestion.completionText
            lastInsertedDefaultPrompt = nil
            Task { await bringMentionIntoChat(item) }
            requestComposerFocus()
            return
        }
        draft = suggestion.completionText
        if suggestion.runsImmediately {
            Task { await submitComposer() }
        }
    }

    /// Brings what an `@` found into this chat, each kind by the path that
    /// already brings it in: a source as `/source` adds it, a Page or a Site as
    /// `/page` and `/site` attach them, a notebook's sources as a dropped
    /// collection adds its sources. A chat waits above the field as a chip;
    /// the send carries its transcript (`chatMentionContext`).
    @MainActor
    private func bringMentionIntoChat(_ item: ChatMention.Item) async {
        switch item.kind {
        case .source:
            await addSourceTokensToChatContext([item.reference])
        case .page, .site:
            await addDocToChatContext(item.reference)
        case .notebook:
            guard let notebook = vm.notebooks.first(where: { $0.id == item.reference }) else { return }
            let sourceIDs = notebook.approvedSourceIDs
            guard !sourceIDs.isEmpty else {
                vm.showToast("\(notebook.title) has no sources yet.")
                return
            }
            await addSourceIDsToChatContext(sourceIDs)
        case .chat:
            guard !composer.referencedChats.contains(where: { $0.reference == item.reference }) else { return }
            composer.referencedChats.append(item)
        }
    }

    /// A card id pasted into the composer becomes a card chip: the card is
    /// read from the kept cards and the cards to check, and the chip shows
    /// its question and opens as a flashcard. An id no card answers to goes
    /// into the field as the text it is.
    @MainActor
    func referencePastedCard(_ id: String) async {
        let snapshot = try? await vm.memoryCardReviewSnapshot(scope: .allNotebooks, includesListings: true)
        let card: ChatReferencedCard?
        if let waiting = snapshot?.toCheck.first(where: { $0.cardID == id }) {
            card = ChatReferencedCard(
                id: waiting.cardID,
                question: waiting.face.front,
                answer: waiting.face.back,
                why: waiting.face.why,
                sourceTitle: vm.articlesById[vm.canonicalSourceID(waiting.sourceID)]?.title
            )
        } else if let kept = snapshot?.cards.first(where: { $0.face.cardID == id || $0.itemID == id }) {
            card = ChatReferencedCard(
                id: kept.face.cardID,
                question: kept.face.front,
                answer: kept.face.back,
                why: kept.face.why,
                sourceTitle: kept.sourceIDs.first.flatMap { vm.articlesById[vm.canonicalSourceID($0)]?.title }
            )
        } else {
            card = nil
        }
        if let card {
            guard !composer.referencedCards.contains(where: { $0.id == card.id }) else { return }
            composer.referencedCards.append(card)
        } else {
            draft = ChatPastedText.field(draft, showing: id)
        }
    }

    /// The reference material for the chats the learner pointed at with `@`:
    /// each one's transcript, read from storage as the message goes, so it
    /// is the chat as it stands now. Nil when none was pointed at.
    @MainActor
    func chatMentionContext(for chats: [ChatMention.Item]) async -> String? {
        guard !chats.isEmpty else { return nil }
        var blocks: [String] = []
        for chat in chats {
            let exchanges: [ReviewExchangeRecord]
            do {
                exchanges = try await vm.storage.loadReviewSessionExchanges(sessionID: chat.reference)
            } catch {
                vm.errorMessage = "Could not read \(chat.title): \(error.localizedDescription)"
                continue
            }
            var turns: [(speaker: String, text: String)] = []
            for exchange in exchanges.sorted(by: { $0.sequenceNumber < $1.sequenceNumber }) {
                if let opening = ReviewSessionManager.displayableMessageContent(role: .assistant, content: exchange.question) {
                    turns.append(("ForeverLM", opening))
                }
                if let answer = exchange.userAnswer {
                    turns.append(("Learner", answer))
                }
                if let reply = exchange.evaluation.flatMap({
                    ReviewSessionManager.displayableMessageContent(role: .assistant, content: $0)
                }) {
                    turns.append(("ForeverLM", reply))
                }
            }
            blocks.append(ChatMention.chatReferenceContext(title: chat.title, turns: turns))
        }
        return blocks.isEmpty ? nil : blocks.joined(separator: "\n\n")
    }

    /// What an `@` query finds: sources through the same index and ranking
    /// as `/source`; Pages and Sites over the lists `/page` and `/site` offer;
    /// the learner's chats (not this one, nor a hidden one or a shared link)
    /// and notebooks by title. Each kind newest first among equal matches.
    @MainActor
    func resolveMentionItems(matching query: String) async -> [ChatMention.Item] {
        guard !query.isEmpty else { return [] }
        var items: [ChatMention.Item] = []

        let index = await vm.artifactSourcePickerIndex()
        let ranked = await Task.detached(priority: .userInitiated) {
            index.rows(matching: query)
        }.value
        items += ranked.prefix(ChatMention.rowsPerTab).map { row in
            ChatMention.Item(kind: .source, reference: row.id, title: row.title, subtitle: row.subtitle)
        }

        for (kind, section) in [(ChatMention.Kind.page, ArtifactSection.docs), (.site, .sites)] {
            let artifacts = slashArtifacts(in: section).sorted { $0.updatedAt > $1.updatedAt }
            items += ChatMention.ranked(artifacts, query: query, title: \.title)
                .prefix(ChatMention.rowsPerTab)
                .map { artifact in
                    ChatMention.Item(
                        kind: kind,
                        reference: artifact.id,
                        title: artifact.title.isEmpty ? "Untitled" : artifact.title,
                        subtitle: Self.slashArtifactSubtitle(for: artifact, section: section)
                    )
                }
        }

        let chats = vm.reviewSessionLinks.filter { record in
            record.id != manager.currentSessionID && !record.isHidden && !record.isExternalLink
                && !record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        items += ChatMention.ranked(chats, query: query, title: \.title)
            .prefix(ChatMention.rowsPerTab)
            .map { record in
                let notebook = record.goalID.flatMap { id in vm.notebooks.first { $0.id == id }?.title }
                let started = record.createdAt.formatted(.relative(presentation: .named))
                return ChatMention.Item(
                    kind: .chat,
                    reference: record.id,
                    title: record.title,
                    subtitle: notebook.map { "\($0) · \(started)" } ?? started
                )
            }

        let notebooks = vm.notebooks.sorted { $0.updatedAt > $1.updatedAt }
        items += ChatMention.ranked(notebooks, query: query, title: \.title)
            .prefix(ChatMention.rowsPerTab)
            .map { notebook in
                let count = notebook.approvedSourceIDs.count
                return ChatMention.Item(
                    kind: .notebook,
                    reference: notebook.id,
                    title: notebook.title,
                    subtitle: count == 1 ? "1 source" : "\(count) sources"
                )
            }
        return items
    }

    /// Runs a `/source`, `/doc` or `/site` command on the row the learner
    /// picked from the popup: a source token (`source:<id>` or `book:<id>`) or
    /// a Doc or Site id. A Site is an artifact record like a Doc — a linked
    /// page or a published Markdown doc — so both attach the same way.
    @MainActor
    private func runSlashReference(_ command: ReviewSlashCommand, reference: String, title: String) async {
        switch command.kind {
        case .source:
            await addSourceTokensToChatContext([reference])
            // Said as `/doc` says it, once the text is in: a pick that only
            // cleared the composer read as nothing happening.
            let ids = ReviewSlashCommandParser.sourceIDs(fromTokens: [reference]) { bookID in
                vm.bookChapterArticlesInOrder(for: bookID).map(\.id)
            }
            if !ids.isEmpty, ids.contains(where: manager.loadedSourceIDs.contains) {
                vm.showToast("Added \(title) to Chat")
            }
        case .doc, .site:
            await addDocToChatContext(reference)
        default:
            break
        }
    }

    /// Adds sources named by picker tokens: a chapter or ordinary source by id,
    /// `book:<id>` for a whole book. The `source:` prefix the popup rows carry
    /// is accepted too, so one resolver serves the popup and the picker sheet.
    @MainActor
    func addSourceTokensToChatContext(_ tokens: [String]) async {
        let ids = ReviewSlashCommandParser.sourceIDs(fromTokens: tokens) { bookID in
            vm.bookChapterArticlesInOrder(for: bookID).map(\.id)
        }
        guard !ids.isEmpty else { return }
        await addSourceIDsToChatContext(ids)
    }

    /// Rows for the `/source`, `/doc` and `/site` popups. Sources go through
    /// the same search as the Docs source picker, so the two agree on what a
    /// query finds and in what order: the title that is the query first, then
    /// titles that start with it, which matters because eight rows is all the
    /// popup shows. Docs and Sites are
    /// few, so they are matched here, each command over its own section — the
    /// split the rail draws (`StudioViewModel.section(of:)`), so `/doc` never
    /// offers a Codex site and `/site` never a draft.
    @MainActor
    func resolveSlashLiveArguments(
        for command: ReviewSlashCommand,
        query: String
    ) async -> [ReviewSlashCommand.Argument] {
        switch command.kind {
        case .source:
            guard !query.isEmpty else { return [] }
            let index = await vm.artifactSourcePickerIndex()
            let ranked = await Task.detached(priority: .userInitiated) {
                index.rows(matching: query)
            }.value
            return ranked.prefix(Self.slashPopupRowLimit).map { row in
                ReviewSlashCommand.Argument(
                    value: row.title,
                    display: row.subtitle,
                    reference: row.id
                )
            }

        case .doc, .site:
            let folded = StudioViewModel.foldedSidebarSearchString(query)
            let terms = folded.split(separator: " ").map(String.init)
            return slashArtifacts(in: command.kind == .site ? .sites : .docs)
                .filter { artifact in
                    guard !terms.isEmpty else { return true }
                    let title = StudioViewModel.foldedSidebarSearchString(artifact.title)
                    return terms.allSatisfy { title.contains($0) }
                }
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(Self.slashPopupRowLimit)
                .map { artifact in
                    ReviewSlashCommand.Argument(
                        value: artifact.title.isEmpty ? "Untitled" : artifact.title,
                        display: Self.slashArtifactSubtitle(for: artifact, section: vm.section(of: artifact)),
                        reference: artifact.id
                    )
                }

        default:
            return []
        }
    }

    private static let slashPopupRowLimit = 8

    /// The records one section's command offers. A member's draft of a team
    /// Doc carries the team copy's title; listing both would be one doc twice.
    /// The draft is added from its own ⋯ menu while it is open. An archived
    /// or a hidden record is off this list as it is off the pane's; the
    /// pane's Archived and Hidden filters are where each is found again.
    @MainActor
    private func slashArtifacts(in section: ArtifactSection) -> [ArtifactRecord] {
        vm.artifacts.filter {
            !TeamContentIdentity.isDraftArtifactID($0.id) && !$0.isArchived && !$0.isHidden
                && !vm.isAudioOverview($0)
                && vm.section(of: $0) == section
        }
    }

    private static func slashArtifactSubtitle(for artifact: ArtifactRecord, section: ArtifactSection) -> String {
        let edited = artifact.updatedAt.formatted(.relative(presentation: .named))
        // A linked page is named as one wherever a doc row appears, so the
        // picker never offers it as if it were a doc the chat could edit; an
        // animation is named as one rather than as the site it is hosted as.
        if artifact.isLinked { return "\(artifact.kindLabel ?? "Linked page") · updated \(edited)" }
        // A Markdown doc in Sites is there because it has a page on foreverlm.com.
        if section == .sites { return "Published page · edited \(edited)" }
        return artifact.isDraft ? "Draft · edited \(edited)" : "Page · edited \(edited)"
    }

    /// Escape over the popup. A `/` draft is only the command, so it goes;
    /// an `@` takes back just itself and what was typed after it, leaving the
    /// rest of the message.
    @MainActor
    func dismissSlashSuggestions() {
        draft = draft.hasPrefix("/") ? "" : ChatMention.removingPending(from: draft)
        slashSelectionIndex = 0
    }

    @MainActor
    func runSlashCommand(_ command: ReviewSlashCommand, argument: String?) async {
        switch command.kind {
        case .goal:
            let topic = argument?.trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt: String
            if let topic, !topic.isEmpty {
                prompt = "I want to set a learning goal about \(topic). Help me settle on the deadline, find sources for it in my library, and plan a schedule."
            } else {
                prompt = Self.setGoalPrompt
            }
            await sendReviewChatMessage(prompt)

        case .source:
            // The popup handles a query that finds something. Submitting past
            // it — a bare `/source`, or a search that matched nothing — opens the
            // Docs source picker seeded with the text, so the learner can
            // browse by type and chapter and add several at once.
            slashSourcePickerRequest = SlashSourcePickerRequest(
                seed: argument?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            )

        case .doc, .site:
            let section: ArtifactSection = command.kind == .site ? .sites : .docs
            let title = argument?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if slashArtifacts(in: section).isEmpty {
                vm.showToast("You have no \(section.title) yet.")
            } else if title.isEmpty {
                // Return on a bare `/doc` or `/site` before the recent list had arrived.
                draft = "/\(command.name) "
            } else {
                vm.showToast("No \(section.noun.capitalized) matches “\(title)”. Pick one from the /\(command.name) suggestions.")
            }

        case .sitePrompt:
            // The tutor writes the prompt from the conversation and its source
            // catalog; the Notebook named is the one this chat is filed under or
            // works in, so the pasted prompt files the Site in the same place.
            let notebookTitle = (linkedResearchNotebook
                ?? vm.activeNotebookId.flatMap { id in vm.notebooks.first { $0.id == id } })?.title
            await sendReviewChatMessage(
                ReviewSlashCommandParser.sitePromptRequest(focus: argument, notebookTitle: notebookTitle)
            )

        case .animate:
            // The chat draws the animation itself and saves it with
            // save_animation linked to this chat's sources; what to animate
            // is the text after the command.
            await sendReviewChatMessage(ReviewSlashCommandParser.animateRequest(focus: argument))

        case .video:
            // Opens the Videos composer with the concept typed after the
            // command. A chat reading exactly one paper or article grounds the
            // film on it, and stands in for the concept when none was typed;
            // the price is asked in the composer, never here.
            let concept = argument?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let grounding = reviewSources.filter {
                ExplainerVideoGeneratorService.groundingSourceTypes.contains($0.sourceType)
                    && !GeneratedExplainer.isSpokenScriptURL($0.url)
            }
            let source = grounding.count == 1 ? grounding.first : nil
            vm.openVideosInReader()
            vm.explainerVideoComposeRequest = ExplainerVideoComposeRequest(
                concept: concept.isEmpty
                    ? source.map { GeneratedExplainerVideo.concept(forSourceTitled: vm.displayTitle(for: $0)) }
                    : concept,
                sourceID: source?.id
            )

        case .course:
            // The planning chat Generate opens, started from here: the
            // learner's topic goes as "I want to make a course about …" with
            // the course-planning instructions beside it.
            guard let context = ChatSkillRequest.contextContent(for: CoursePlanningChat.skill) else { return }
            await sendReviewChatMessage(
                CoursePlanningChat.request(topic: argument ?? ""),
                contextualContent: context
            )

        case .today:
            // What is on the calendar right now, which is the day's question
            // rather than the Schedule's. Planning a day is /plan.
            await sendReviewChatMessage(
                "Read today's calendar and tell me what I am in now and what it is for, "
                + "and what is still ahead today."
            )

        case .plan:
            // The day on the calendar. The conversation reads the day, the
            // Goals and the recent logs before it asks anything, and it writes
            // the whole day once it is agreed rather than an event at a time.
            await sendReviewChatMessage(
                ReviewSlashCommandParser.planDayRequest(argument),
                contextualContent: ReviewSlashCommandParser.planDayContextContent
            )

        case .review:
            guard !manager.isSearching, !manager.isGenerating else {
                vm.showToast("Wait for the current response before starting a review.")
                return
            }
            if !reviewSources.isEmpty {
                await startRequestedReviewChat()
                return
            }
            if let notebook = linkedResearchNotebook ?? idleSuggestedReviewNotebook {
                await startNotebookReviewFromIdle(notebook)
                return
            }
            vm.showToast("Add sources or choose a notebook before starting a review.")

        case .notebook:
            guard let argument, !argument.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                vm.showSpaceAll()
                return
            }
            let matches = vm.notebooks.filter {
                $0.title.compare(argument, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }
            guard matches.count == 1, let notebook = matches.first else {
                vm.showToast(matches.isEmpty
                    ? "Notebook not found. Choose one from the /notebook suggestions."
                    : "More than one notebook has that name. Rename one before switching.")
                return
            }
            // `/notebook` chooses the active Notebook explicitly, then opens
            // the notebook in this window with a New chat in it.
            vm.activeNotebookId = notebook.id
            let openNotebook = { vm.openNotebook(notebook.id, startsNotebookChat: false) }
            if let windowState { vm.inWindow(windowState, openNotebook) } else { openNotebook() }
            vm.requestBlankReviewChat(notebookID: notebook.id)

        case .new:
            if let windowState {
                vm.inWindow(windowState) { vm.requestNewChat() }
            } else {
                vm.requestNewChat()
            }
            clearComposer()

        case .model:
            guard let argument, !argument.isEmpty else {
                vm.showToast("Usage: /model <model-id>")
                return
            }
            let provider = KeychainService.resolvedProvider(for: .chat)
            KeychainService.setTaskProvider(provider, for: .chat)
            KeychainService.setTaskModel(argument, for: .chat)
            vm.showToast("Chat model set to \(argument).")

        case .settings:
            if let argument, ReviewSlashCommandParser.namesPlugins(argument) {
                PluginsPlace.requestOpen()
            } else {
                let pane = argument.flatMap(ReviewSlashCommandParser.parseSettingsPane)
                NotificationCenter.default.post(name: .requestOpenStudioSettings, object: pane)
            }

        case .end:
            await manager.completeSession()
            await refreshAfterReviewChatTurn()

        case .help:
            // Re-open the popup with the full command list.
            draft = "/"

        case .skill:
            // The learner's words go as typed, command included, so the
            // transcript shows which skill answered; the skill's instructions,
            // as they stand now, ride beside them (`ChatSkillRequest`).
            guard let skill = SkillLibrary.shared.skills.skill(named: command.name),
                  let context = ChatSkillRequest.contextContent(
                      for: ChatSkillRequest.Skill(name: skill.name, instructions: skill.instructions)
                  ) else {
                // The Plugins place's Skills tab lists them, as Codex's does.
                vm.showToast(
                    "The skill /\(command.name) is gone. Plugins › Skills lists the ones you have.",
                    action: StudioToastAction(title: "Show Skills") { [vm] window in
                        vm.openPluginsPlace(at: .skills, in: window)
                    }
                )
                return
            }
            let request = argument.map { "/\(skill.name) \($0)" } ?? "/\(skill.name)"
            await sendReviewChatMessage(request, contextualContent: context)

        case .rename:
            guard let record = openChatRecord, canRenameChat else {
                vm.showToast(manager.currentSessionID == nil
                    ? "A new chat takes its name from its first message."
                    : "This chat can't be renamed here.")
                return
            }
            let title = argument?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if title.isEmpty {
                // No name typed: the title opens for editing, as a click on it does.
                beginChatTitleRename()
            } else if title != record.title {
                await vm.renameReviewSession(record.id, title: title)
            }

        case .pin:
            guard let record = openChatRecord, !MemoryReviewSession.isMemorySession(record.id) else {
                vm.showToast("Send a message first: a new chat has nothing to pin yet.")
                return
            }
            let pinned = !vm.isChatPinned(record.id)
            vm.setChatPinned(record.id, pinned: pinned)
            vm.showToast(pinned ? "Chat pinned" : "Chat unpinned")

        case .hide:
            guard let record = openChatRecord, !MemoryReviewSession.isMemorySession(record.id) else {
                vm.showToast("Send a message first: a new chat has nothing to hide yet.")
                return
            }
            await vm.setReviewSessionHidden(record.id, hidden: !record.isHidden)
            vm.showToast(record.isHidden ? "Chat shown in Chats again" : "Chat hidden from Chats")

        case .fork:
            guard manager.currentSessionID != nil, !manager.chatMessages.isEmpty else {
                vm.showToast("Send a message first: there is nothing to branch yet.")
                return
            }
            // Branch in New Chat over the whole thread: the reply ⋯'s Branch,
            // from the newest saved turn.
            forkConversation(through: manager.chatMessages)

        case .side:
            openThreadSideChat()

        case .reasoning:
            await setChatReasoning(argument)
        }
    }

    /// `/reasoning <effort>`: the chat's effort, as the model chip's Effort
    /// submenu sets it, and the effort later chats start on. A bare
    /// `/reasoning` offers the efforts; one the model does not take is
    /// refused with the ones it does.
    @MainActor
    private func setChatReasoning(_ argument: String?) async {
        let offered = await Task.detached(priority: .userInitiated) {
            let selection = KeychainService.resolvedSelection(for: .chat)
            return AIRequestOptionSupport.supportedEfforts(provider: selection.provider, model: selection.model)
        }.value
        guard !offered.isEmpty else {
            vm.showToast("This chat's model has no reasoning effort to set.")
            return
        }
        guard let argument, !argument.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            draft = "/reasoning "
            return
        }
        let names = offered.map(\.displayName).joined(separator: ", ")
        guard let effort = ReviewSlashCommandParser.effort(named: argument) else {
            vm.showToast("Reasoning is one of: \(names).")
            return
        }
        guard offered.contains(effort) else {
            vm.showToast("This model takes \(names).")
            return
        }
        KeychainService.setTaskEffort(effort, for: .chat)
        KeychainService.chosenChatEffort = effort
        vm.showToast("Reasoning: \(effort.displayName)")
    }

    @MainActor
    func finishManualDictationTranscription() async -> String? {
        if let task = manualDictationTranscriptionTask {
            let text = await task.value
            manualDictationTranscriptionTask = nil
            return text
        }

        guard dictation.isRecording else { return nil }
        let task = Task { @MainActor in
            await dictation.stopAndTranscribe()
        }
        manualDictationTranscriptionTask = task
        let text = await task.value
        manualDictationTranscriptionTask = nil
        return text
    }

    func combinedComposerText(draft: String, transcript: String) -> String {
        let baseDraft = draft == lastInsertedDefaultPrompt ? "" : draft
        let trimmedDraft = baseDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDraft.isEmpty else { return trimmedTranscript }
        guard !trimmedTranscript.isEmpty else { return trimmedDraft }
        return "\(trimmedDraft)\n\(trimmedTranscript)"
    }

    @MainActor
    func sendReviewChatMessage(
        _ text: String,
        contextualContent: String? = nil,
        docAnchor: ChatDocAnchor? = nil
    ) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        adoptLiveNotebookSelection()
        // A message sent in a notebook's chat is working in that notebook:
        // the next window opens it, and the home's Recent order leads with it.
        if let notebookID = linkedResearchNotebook?.id {
            vm.noteNotebookWork(notebookID)
            // A kept question typed rather than clicked is asked all the same.
            vm.noteNotebookQuestionAsked(trimmed, notebookID: notebookID)
        }
        let targetManager = manager
        targetManager.beginGenerationPreparation()
        targetManager.beginSendPreparationTrace()
        // Released the moment the turn itself is over, not when this function
        // returns. The post-turn refresh below reloads the article list, the
        // session links and the companion plan — seconds of work the learner
        // never asked about — and holding the lease across it left the working
        // indicator spinning under a reply that had already finished streaming.
        var preparationLeaseHeld = true
        func releasePreparationLease() {
            guard preparationLeaseHeld else { return }
            preparationLeaseHeld = false
            targetManager.endGenerationPreparation()
        }
        defer { releasePreparationLease() }

        // Sending the default opening prompt starts the session without echoing it as a
        // message, so that one branch gets no bubble. Decided up front, since appending
        // the bubble below is itself what would make `chatMessages` non-empty.
        let hasContextualContent = contextualContent?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        let startsAutomaticSession = !hasContextualContent
            && !targetManager.sessionActive
            && targetManager.chatMessages.isEmpty
            && trimmed == defaultInitialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)

        // The bubble goes up before the first await. Everything below — synthesis
        // context, source hydration, session reopen — can take seconds, and a message
        // that isn't on screen by then reads as the send having been dropped.
        if !startsAutomaticSession {
            targetManager.showUserMessage(trimmed, contextualContent: contextualContent)
        }

        guard await syncSynthesisToolContext() else {
            targetManager.discardOptimisticUserMessage(trimmed)
            targetManager.discardSendPreparationTrace()
            return
        }
        targetManager.markSendPreparation("Notebook files")

        // Attached sources are fetched lazily (only when opened in the reader), so a
        // source dropped straight onto the chat — e.g. a YouTube video — would reach
        // the model with no readable text. Hydrate any missing attached sources first.
        await vm.ensureContextSourceContentLoaded { detail in
            targetManager.setSendPreparationDetail(detail)
        }
        targetManager.setSendPreparationDetail(nil)
        targetManager.markSendPreparation("source download")

        if startsAutomaticSession {
            await targetManager.startSession(
                topic: reviewTitle.isEmpty ? trimmed : reviewTitle,
                articles: reviewSources,
                mode: targetManager.currentPromptMode,
                goalID: linkedResearchNotebookID,
                notebookScopeID: linkedResearchNotebookID
            )
        } else {
            await targetManager.sendMessage(
                text,
                topic: reviewTitle,
                articles: reviewSources,
                initialMode: targetManager.currentPromptMode,
                goalID: linkedResearchNotebookID,
                notebookScopeID: linkedResearchNotebookID,
                contextualContent: contextualContent,
                docAnchor: docAnchor
            )
        }

        releasePreparationLease()
        // A first send that never made a session leaves the messages queued
        // behind it with no turn to follow. They go back to the composer, in
        // this pane only: another chat's draft is not theirs.
        if !targetManager.sessionActive, !targetManager.hasGenerationWorkInFlight,
           targetManager === manager {
            returnQueuedFollowUpsToComposer()
        }
        await refreshAfterReviewChatTurn()
    }

    /// Puts every queued message back into the composer, oldest first, ahead
    /// of anything already typed, and restores the passage the first of them
    /// was about if the composer has none.
    @MainActor
    func returnQueuedFollowUpsToComposer() {
        let returned = manager.takeQueuedFollowUps()
        guard !returned.isEmpty else { return }
        // Newest first: each goes in ahead of the draft, so the oldest ends up
        // at the top, in the order they were sent.
        for item in returned.reversed() {
            returnQueuedFollowUpToComposer(item)
        }
    }

    /// Delete on a queued message: it is not sent, and nothing of it is kept.
    @MainActor
    func deleteQueuedFollowUp(_ item: ReviewSessionManager.QueuedFollowUp) {
        manager.removeQueuedFollowUp(item.id)
        queuedReaderSelections.removeValue(forKey: item.id)
    }

    /// One queued message back into the composer: its words join the draft on
    /// their own line and its passage becomes the pending selection again.
    @MainActor
    func returnQueuedFollowUpToComposer(_ item: ReviewSessionManager.QueuedFollowUp) {
        manager.removeQueuedFollowUp(item.id)
        let base = draft == lastInsertedDefaultPrompt ? "" : draft
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = trimmedBase.isEmpty ? item.text : "\(item.text)\n\(trimmedBase)"
        lastInsertedDefaultPrompt = nil
        if let selection = queuedReaderSelections.removeValue(forKey: item.id), pendingReaderSelection == nil {
            pendingReaderSelection = selection
        }
        requestComposerFocus()
    }

    @MainActor
    private func refreshAfterReviewChatTurn() async {
        await vm.refreshArticles()
        await vm.loadReviewSessionLinks()
        await vm.loadLearningGoals()
        await vm.refreshMemoryCompanionPlan()
    }

    /// A passage selected in one of this transcript's replies, held beside the
    /// composer and drawn above the field as a quote. It is not typed into the
    /// draft: the learner writes only the question, and the send folds the
    /// passage in ahead of it as a blockquote.
    @MainActor
    /// Opens the chat's Browser tab in the pane of the window that holds it.
    func revealChatBrowserTab() {
        guard let agent = manager.browserAgent as? StudioChatBrowserAgent, agent.hasTab else { return }
        let destination = agent.tabWindowID.flatMap { id in
            StudioWindowRegistry.shared.states.first { $0.id == id }
        }
        vm.activateCenterTab(.browser, in: destination)
        agent.revealTab()
    }
}
