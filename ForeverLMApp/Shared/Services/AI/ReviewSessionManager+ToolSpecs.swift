// Part of ReviewSessionManager: the app tool surface, deferral and native tool specs.

import Foundation

extension ReviewSessionManager {
    /// `turns` with a retry directive at the end. After tool results it is a
    /// message of its own; after the learner's message it joins that message,
    /// so the request never carries two learner turns in a row. Either way the
    /// cached request ahead of it is unchanged.
    static func nativeTurns(_ turns: [AIChatTurn], endingWith directive: String) -> [AIChatTurn] {
        guard case .user(let text, let images)? = turns.last else {
            return turns + [.user(directive)]
        }
        return turns.dropLast() + [.user(text + "\n\n" + directive, images: images)]
    }

    /// App tools the study-oriented prompt kinds (`review`, `study`, `summarize`)
    /// expose. Those chats work the attached sources rather than administering the
    /// library, so they carry a small reading/annotation surface instead of the full
    /// ~100-tool MCP catalog — which costs roughly 16k tokens of every request.
    ///
    /// Deliberately excluded: the review-session tools. A study chat already is the
    /// review, persisted by `completeSession()`, so `start_review_session` and
    /// `end_review_session` would add nothing. Agent chats do carry them; there
    /// every call binds to the chat's own session through `hostSessionID`, and the
    /// schema they see drops the caller-owned arguments (`MCPToolDef.inAppInputSchema`).
    ///
    /// One set covers all three kinds on purpose. A review chat alternates between
    /// `.review` and `.study` as the learner sends messages (see
    /// `sessionPromptKindForUserMessage`), so per-kind sets would change the tool
    /// block every turn and thrash the cached prefix.
    static let studySurfaceToolNames: Set<String> = [
        "list_sources",
        "get_source_content",
        "search_sources_semantic",
        // "Which Huberman episodes are about mitochondria" asked in a paper's
        // chat is a list by show, and a ranked search over the whole library
        // let every other mitochondria podcast crowd out the one episode that
        // mattered. The listing and the exact-word sweep are what
        // answer a request for the complete set.
        "filter_sources",
        "list_shows",
        "search_sources_keyword",
        // A review or research chat that brings up a paper the library lacks can
        // add it on request instead of sending the learner to the composer.
        "import_paper_from_url",
        // "Find all the linked sources" is said in the chat about the article
        // (product owner, 2026-09-14): the scan lists them, the learner picks, and the
        // import adds only those. Dismissal stays in the reader's panel.
        "scan_article_for_linked_sources",
        "import_video_cited_paper",
        // Slack is where a reading group announces what to read, and the chat a
        // learner asks about it in is the chat on the Notebook or the paper — a
        // study chat, not the agent surface. Without these two a study chat can
        // only search the library, and a library search never says what a
        // channel says (a Notebook chat asked about a PDF posted that week
        // showed nine "Searched sources" rows and no Slack read).
        "list_slack_channels",
        "read_slack_channel",
        "read_slack_thread",
        "search_slack_messages",
        // The Slack guidance ends a PDF hunt by attaching the posted file to the
        // paper it belongs to; the tool has to be reachable from the same chat.
        "attach_pdf_to_paper",
        "get_notebook_context",
        "add_notebook_sources",
        "list_notebook_files",
        "read_notebook_markdown_file",
        "write_notebook_markdown_file",
        "list_docs",
        "create_doc",
        "read_doc",
        "write_doc",
        // A long Doc cannot be re-emitted through write_doc (a chat
        // asked to fold a Google Doc's ideas into two reports, one of 237k
        // characters, created a third Doc rather than risk truncating them).
        // edit_doc changes passages in place, and publish_doc is how a chat
        // asked to fix a published page gets the edit onto foreverlm.com.
        "edit_doc",
        "update_doc",
        "publish_doc",
        // A linked Codex site or Claude artifact the learner wants to edit
        // here becomes ForeverLM's own published page in one call.
        "adopt_page",
        // "make a site" means a site, not a Doc (product owner, 2026-09-09): HTML
        // the chat writes is kept in the library and served as written, and
        // never put on the web.
        "save_site",
        "read_site_file",
        // "show me how it works" on a paper means an animation (product owner,
        // 2026-09-17): code the chat writes that plays, kept like a site
        // and linked to the paper. The chat about the paper is where it is
        // asked for, so a study chat carries the maker, the list and the
        // remover.
        "save_animation",
        "list_animations",
        "delete_animation",
        // "Walk me through this paper" in the chat about the paper: the steps
        // the Reader's Walk Through panel follows beside the PDF, written by
        // the app or authored by the chat itself (walkthrough-design.md).
        "generate_walkthrough",
        "get_walkthrough",
        "list_walkthroughs",
        "save_walkthrough",
        // "Make cards" from the chat about the source (decision 3): the chat drafts them
        // itself and saves them, free, to wait in Memory's To Check until the learner keeps them — or, asked to,
        // has ForeverLM draft them from the sources' whole text with the
        // learner's Card Drafting model, priced first like every paid maker.
        "save_card_drafts",
        "draft_cards",
        // "Quiz me on this paper's cards" is said in the chat about it too:
        // the chat chooses the kept cards and the app's card
        // review opens on them.
        "list_cards",
        // "Which sources have no cards yet?" is asked in the chat too: the
        // chat lists them and makes the cards, or removes what the learner
        // says is not worth keeping (remove_source).
        "list_source_card_coverage",
        // A card also stands on the other sources that state it: the chat
        // that drafts cards finds them and names them with each card.
        "find_card_sources",
        // An argument's card and its steps' cards, linked after they were saved.
        "set_card_details",
        "practice_cards",
        // "Make a mnemonic reading of this book" is said in the chat about
        // the book: ForeverLM writes the questions, priced first
        // like draft_cards, or the chat saves its own, free. Going through a
        // reading is done in the reading itself, not in a chat, so the
        // reading and answering tools stay with the agent surface.
        "generate_mnemonic_reading",
        "save_mnemonic_reading",
        // The notes about the learner's work: "remember that", "forget that"
        // are said in any chat.
        "list_working_notes",
        "save_working_note",
        "update_working_note",
        "forget_working_note",
        "list_open_questions",
        "create_open_question",
        "update_open_question",
        "update_notebook_notes",
        "append_notebook_notes",
        // A reading or review chat is where "make this a scheduled task" actually
        // gets said, and the source under discussion is the referent. Creation
        // only: administering existing tasks belongs to the Tasks pane and the
        // agent chat, and every tool listed here is paid for on every study turn.
        "create_scheduled_task",
        // "Add reading this chapter to my board" is said in the chat about the
        // book (product owner, 2026-11-25). Without it a reading chat found the
        // chapter and answered that it could not add a to-do. With no
        // notebook_id the task lands on the learner's Board.
        "create_notebook_task",
        // "Plan my day and schedule those papers" is said in the chat about the
        // papers. A study chat that has create_scheduled_task and no day tool
        // makes one-off scheduled tasks, tells the learner the papers are
        // scheduled, and leaves the day empty. Putting a reading on
        // the clock is an event on the Mac's Calendar; the goals are what it
        // serves.
        "get_calendar_events",
        "create_calendar_event",
        "update_calendar_event",
        "delete_calendar_event",
        "list_goals",
        "get_goal",
        // "Open this notebook", "show me that paper" are said in any chat, and
        // a study chat had no way to put anything on screen: asked to open the
        // Notebook it had just made, a chat answered that it had opened it and
        // nothing moved. open_in_app does what a click does;
        // list_notebooks finds a Notebook the learner names by its title.
        "open_in_app",
        "list_notebooks",
        // "Can you make audio of this book, with a free voice?" is said in the
        // chat about the book. Without these a reading chat answered that it
        // could not generate speech and sent the learner to Terminal's `say`
        // (2026-11-17). set_app_setting switches to a free speech model when
        // the learner picks one from generate_source_audio's quote.
        "generate_source_audio",
        "get_source_audio_status",
        "cancel_source_audio_generation",
        "set_app_setting",
    ]

    /// What Deep Research carries beyond the study surface: the reader's
    /// marks. What's New researches what has changed since a source was
    /// written and writes the short version onto the mark it was opened on,
    /// and a research run asked to note what a chapter got wrong marks those
    /// passages itself (chat-design.md, "What's New").
    static let deepResearchExtraToolNames: Set<String> = [
        "list_source_highlights",
        "create_source_highlight",
        "update_source_highlight",
        // A direction search is a research run with its own home and steps
        // (docs/directions-design.md): the brief, the literature, and the
        // writes that save what it kept and record the learner's answers.
        "find_directions",
        "search_literature",
        "propose_directions",
        "list_directions",
        "update_direction",
        "list_ideas",
    ]

    /// Tools the app exposes over MCP that do not belong in a chat turn.
    ///
    /// Every tool definition is sent on every request, and the full catalog had
    /// grown to roughly 20k tokens — about half the prompt — which the model pays
    /// for in time-to-first-token on any turn that does not hit a warm cache. What
    /// is excluded here is plugin and maintenance plumbing: it is reached from
    /// the app's own UI or from an external MCP assistant, and a learner does not
    /// ask for it mid-conversation. Everything a learner might actually say out
    /// loud — add this paper, find that source, archive it, plan my week, quiz me —
    /// stays.
    ///
    /// This is an exclusion set rather than an allow-list on purpose: a newly added
    /// tool reaches chat by default, so the parity between what the app can do and
    /// what the assistant can do is not quietly lost every time someone adds a tool.
    /// Excluding one is a deliberate act. Nothing here is removed from MCP itself.
    static let chatExcludedToolNames: Set<String> = [
        // The sidebar's selected Notebook. An in-app chat already knows its scope:
        // a chat opened under a Notebook carries that Notebook in
        // `notebookSourceScopeID`, and a chat outside every Notebook has none. The
        // row highlighted in the sidebar answers neither — it is whatever the
        // learner last clicked, and reading it let a chat that lives outside any
        // Notebook adopt the Notebook the sidebar happened to show. Only an
        // external MCP assistant, which cannot see the window, needs this tool.
        "get_app_context",
        // The library page the ForeverLM home inside Claude, Codex and ChatGPT
        // draws: thumbnails as data URLs, for a view, never for a model.
        "browse_library",
        // X posting: an assistant-facing surface, not an in-app chat job.
        "create_x_post",
        // Images over MCP. The chat has its own generate_image and
        // list_generated_images, which paste the picture's line into the
        // answer; sending the MCP twin as well would put two definitions
        // named generate_image in one request, which providers refuse.
        "list_images", "get_image", "generate_image", "save_image", "rename_image", "delete_image",
        // Meeting import and grouping.
        "list_meeting_groups", "get_meeting_group", "attach_meeting_artifact",
        "import_meeting_transcript_files", "transcribe_meeting_recording",
        "rename_group",
        // Podcast matching and episode visibility.
        "find_podcast_match", "resolve_podcast_match", "remove_all_from_podcast",
        // Course lecture assembly.
        "create_course_lecture", "add_source_to_lecture", "add_paper_to_lecture",
        "remove_course_lecture_item", "rename_course_lecture",
        // Paper and source maintenance: batch repair, dedup, metadata extraction.
        "download_papers_needing_attention", "recheck_paywalled_papers", "find_duplicate_papers",
        // attach_pdf_to_paper stays: it is how a PDF posted in Slack is filed
        // from the chat (see the Slack guidance), and the study surface lists it.
        "attach_text_file_to_source",
        "extract_paper_metadata", "extract_article_metadata",
        "set_source_paywall_status", "clear_source_derived_data",
        "fetch_source_from_archive",
        // Plugin scheduling.
        "set_connector_auto_import", "follow_youtube_liked_videos",
        "follow_youtube_foreverlm_playlist",
        "refresh_youtube_sources",
        // Transport plumbing: in-app chat is already inside the app.
        "get_mcp_status", "list_source_actions",
        // A notebook's Discover for outside assistants. Chat searches the web
        // itself; a tool that runs a second model on a web search would bill
        // twice and be the feature-specific assistant chat-design rules out.
        "discover_sources",
    ]

    /// App tools visible to the current prompt kind. `.agent` is the "command the
    /// app" surface and keeps everything except `chatExcludedToolNames`; study kinds
    /// are scoped much harder, to `studySurfaceToolNames`.
    ///
    /// The result must stay constant for a given prompt kind: it lands in the stable,
    /// cached half of the request, so anything that varies per turn (recent activity,
    /// heuristic relevance) would invalidate the prefix on every request and cost far
    /// more than the tools it dropped.
    func sessionAppToolDefinitions() -> [AppToolDefinition] {
        let tools = appToolDefinitions()
        let promptTools: [AppToolDefinition]
        switch sessionPromptKind {
        case .agent:
            promptTools = tools.filter { !Self.chatExcludedToolNames.contains($0.name) }
        case .review, .study, .summarize, .shallowRead, .deepRead, .teachBack:
            promptTools = tools.filter { Self.studySurfaceToolNames.contains($0.name) }
        case .deepResearch:
            // A Deep Research chat never alternates with the review kinds, so
            // its few extra tools do not thrash their cached prefix.
            promptTools = tools.filter {
                Self.studySurfaceToolNames.contains($0.name) || Self.deepResearchExtraToolNames.contains($0.name)
            }
        }
        // A tool the chat runs itself against its attached sources is not sent
        // a second time under the MCP twin's name: two definitions with one
        // name is a request the providers refuse.
        let nativeNames = nativeToolNamesForAttachedSources
        return promptTools.filter { !nativeNames.contains($0.name) }
    }

    /// App tools that `nativeToolSpecs` defines itself when sources are
    /// attached, in place of the MCP tool of the same name. The chat's own
    /// version resolves the source against the attached pool, shows progress
    /// on its activity row, and hands back the slide listing ready to paste.
    static let chatNativeToolNames: Set<String> = ["extract_video_slides"]

    private var nativeToolNamesForAttachedSources: Set<String> {
        activeSourceIDs.isEmpty || sourceManifest.isEmpty ? [] : Self.chatNativeToolNames
    }

    /// App tools a chat always carries in full. A plain chat on one podcast
    /// took a minute to answer a short question: the request was 177k tokens,
    /// about 125k of them the schemas of every app tool, re-read on every
    /// round of every turn by a model with no prompt cache (product owner,
    /// 2026-10-12: "i cannot be waiting 1 minute for response"). The everyday reading, Notebook, Page
    /// and calendar tools travel whole; the rest are named in
    /// `load_app_tools` and join the request when the chat loads them.
    static let coreAppToolNames: Set<String> = [
        "search_sources_semantic", "search_sources_keyword", "filter_sources",
        "list_shows", "get_source_content", "list_sources",
        "get_notebook_context", "add_notebook_sources", "list_notebook_sources",
        "list_notebooks", "get_notebook", "create_notebook", "update_notebook", "open_in_app",
        // Rename, pin, hide or move this chat into a Notebook: said aloud in a
        // chat, so it travels whole rather than behind a load step.
        "update_review_session",
        // "Add this to my board" is said mid-chat. Every surface is over the
        // deferral budget (a study chat's is ~134k characters), so a to-do tool
        // left out of the core set waited behind load_app_tools and a review
        // chat answered that it could not add the to-do (product owner,
        // 2026-11-25, twice). With no notebook_id it lands on the Board.
        "create_notebook_task",
        "list_docs", "read_doc", "create_doc", "edit_doc", "write_doc",
        "import_paper_from_url",
        "list_goals", "get_schedule", "get_today_sources",
        "get_calendar_events", "create_calendar_event", "update_calendar_event",
        "get_day_activity", "list_working_notes", "save_working_note",
        // The quarter's plan, which /plan reads before a week or a day.
        "get_plan",
        "list_ideas", "list_open_questions",
    ]

    /// Characters of app-tool definitions a request carries before the tools
    /// outside `coreAppToolNames` wait for `load_app_tools`. A surface this
    /// small sends everything; the full catalog is about 520k characters.
    static let appToolDeferralBudgetCharacters = 40_000

    static let loadAppToolsName = "load_app_tools"

    private var loadedAppToolNames: [String] {
        loadedAppTools.sessionID == sessionID ? loadedAppTools.names : []
    }

    /// The session's app tools split into those sent whole and those named
    /// only in `load_app_tools`. Deferral is all or nothing per surface: a
    /// surface under the budget sends every tool, as before.
    private func appToolSurface() -> (sent: [AppToolDefinition], deferred: [AppToolDefinition]) {
        let tools = sessionAppToolDefinitions()
        let total = tools.reduce(0) { $0 + $1.name.count + $1.description.count + $1.inputSchemaJSON.count + 32 }
        guard total > Self.appToolDeferralBudgetCharacters, sessionPromptKind != .deepResearch else {
            return (tools, [])
        }
        let loaded = loadedAppToolNames
        let core = tools.filter { Self.coreAppToolNames.contains($0.name) }
        let byName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let loadedTools = loaded.compactMap { name in
            Self.coreAppToolNames.contains(name) ? nil : byName[name]
        }
        let sentNames = Set(core.map(\.name)).union(loadedTools.map(\.name))
        return (core + loadedTools, tools.filter { !sentNames.contains($0.name) })
    }

    private static func loadAppToolsSpec(deferred: [AppToolDefinition]) -> AIToolSpec {
        let names = deferred.map(\.name).sorted().joined(separator: ", ")
        return AIToolSpec(
            name: loadAppToolsName,
            description: "Load more ForeverLM app tools. Your tool list carries the everyday ones; these others exist too, and a loaded tool joins your tool list for the rest of this chat. Load a tool before calling it — including one these instructions name that is not in your list — and load several at once when a task needs them. Pass names from this list, or a query to find tools by what they do: \(names)",
            inputSchema: [
                "type": "object",
                "properties": [
                    "names": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Exact tool names from the list."
                    ] as [String: Any],
                    "query": [
                        "type": "string",
                        "description": "Words describing the action, when no name fits. Loads the best few matches."
                    ],
                ] as [String: Any],
            ]
        )
    }

    /// Loads the asked-for tools into this session's request and says what
    /// each one does, so the next round can call it.
    func loadAppTools(arguments: [String: Any]) -> AppToolResult {
        let surface = appToolSurface()
        let deferred = surface.deferred
        let byName = Dictionary(deferred.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let alreadySent = Set(surface.sent.map(\.name))
        let asked = (arguments["names"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var picked = asked.compactMap { byName[$0] }
        let unknown = asked.filter { byName[$0] == nil && !alreadySent.contains($0) }
        if let query = Self.nonEmptyTrimmed(arguments["query"] as? String) {
            picked += Self.appTools(matching: query, in: deferred, limit: 6)
                .filter { tool in !picked.contains { $0.name == tool.name } }
        }
        guard !picked.isEmpty else {
            let already = asked.filter { alreadySent.contains($0) }
            if !already.isEmpty, unknown.isEmpty {
                return AppToolResult(text: "Already in your tool list: \(already.joined(separator: ", ")). Call it now.", isError: false)
            }
            return AppToolResult(
                text: "Error: No tool matched. Pass exact names from the load_app_tools list.",
                isError: true
            )
        }
        var names = loadedAppToolNames
        names += picked.map(\.name).filter { !names.contains($0) }
        loadedAppTools = (sessionID, names)
        var lines = ["Loaded into your tool list; call them now:"]
        lines += picked.map { tool in
            let summary = tool.description.split(separator: "\n").first.map(String.init) ?? tool.description
            return "- \(tool.name): \(summary.prefix(240))"
        }
        if !unknown.isEmpty {
            lines.append("Not tools here: \(unknown.joined(separator: ", ")).")
        }
        return AppToolResult(text: lines.joined(separator: "\n"), isError: false)
    }

    /// Deferred tools ranked by how many of the query's words their name and
    /// description carry; the name counts double.
    nonisolated static func appTools(
        matching query: String,
        in tools: [AppToolDefinition],
        limit: Int
    ) -> [AppToolDefinition] {
        let words = query.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 2 }
        guard !words.isEmpty else { return [] }
        let scored: [(tool: AppToolDefinition, score: Int)] = tools.map { tool in
            let name = tool.name.lowercased()
            let description = tool.description.lowercased()
            let score = words.reduce(0) { partial, word in
                partial + (name.contains(word) ? 2 : 0) + (description.contains(word) ? 1 : 0)
            }
            return (tool, score)
        }
        return scored
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map(\.tool)
    }

    static func nonEmptyTrimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Which of a reopened chat's sources come back loaded.
    ///
    /// `remembered` is what the chat had read when it was last open, as this
    /// Mac recorded it (schema 104); when there is a record it is the answer,
    /// trimmed to the sources still attached. A chat recorded before the loaded
    /// set was kept has only its transcript to go on, so it reopens holding
    /// what the conversation cited — `ChatSourceEvidence`'s rule, under which
    /// a chat with a single attached source is about that source whether or
    /// not a turn linked it — and never a Notebook pool that was only ever
    /// catalog.
    /// What a reopened chat reads on demand: the sources its transcript says
    /// the learner added ("Added 9 book chapters to context") that are still
    /// attached and whose text is not held. Read off the marks, so nothing
    /// new is stored for it.
    nonisolated static func onDemandSourceIDsOnResume(
        attached: [String],
        loaded: Set<String>,
        exchanges: [ReviewExchangeRecord]
    ) -> Set<String> {
        let added = exchanges.flatMap { ChatContextAdditions.parse(contextContent: $0.contextContent).added.map(\.id) }
        return Set(added).intersection(attached).subtracting(loaded)
    }

    nonisolated static func sourceIDsToReloadOnResume(
        remembered: [String]?,
        attached: [String],
        exchanges: [ReviewExchangeRecord]
    ) -> Set<String> {
        let attachedSet = Set(attached)
        if let remembered {
            return Set(remembered).intersection(attachedSet)
        }
        let cited = exchanges.flatMap { exchange in
            ChatSourceEvidence.sourceLinkTokens(
                question: exchange.question,
                userAnswer: exchange.userAnswer,
                evaluation: exchange.evaluation
            )
        }
        return ChatSourceEvidence.discussedSourceIDs(attached: attached, cited: cited)
            .intersection(attachedSet)
    }

    /// Reads whether this chat's Notebook takes the imports the chat asks for
    /// (`notebookImportFiling`): once per turn, before the prompt is built. A
    /// read that fails leaves it unknown, so this turn's imports go to the
    /// library only and the prompt promises nothing.
    func refreshNotebookImportFiling() async {
        guard let notebookID = notebookSourceScopeID else {
            notebookImportFiling = nil
            madeThingFiling = nil
            return
        }
        // `var`: a read of the Goal's parent can throw after `filing` is set,
        // and the catch then makes both unknown.
        var filing: NotebookImportFiling?
        var madeThings: MadeThingFiling?
        do {
            let notebook = try await storage.loadLearningGoal(notebookID)
            var team: TeamRecord?
            if let teamID = notebook?.teamID {
                team = try await storage.loadTeam(teamID)
            }
            filing = NotebookImportRefusal.refusal(for: notebook, team: team).map { .libraryOnly($0) } ?? .files
            // What the chat makes lives in the Notebook itself, or in the
            // Notebook of the Goal the chat is filed on.
            if let notebook, notebook.isNotebook, let filing {
                madeThings = MadeThingFiling(notebookID: notebook.id, filing: filing, teamID: notebook.teamID)
            } else if let parentID = notebook?.parentNotebookID,
                      let parent = try await storage.loadLearningGoal(parentID), parent.isNotebook {
                var parentTeam: TeamRecord?
                if let teamID = parent.teamID {
                    parentTeam = try await storage.loadTeam(teamID)
                }
                let parentFiling: NotebookImportFiling = NotebookImportRefusal.refusal(for: parent, team: parentTeam)
                    .map { .libraryOnly($0) } ?? .files
                madeThings = MadeThingFiling(notebookID: parent.id, filing: parentFiling, teamID: parent.teamID)
            }
        } catch {
            logger.error("Could not read whether Notebook \(notebookID, privacy: .public) takes imports: \(error.localizedDescription, privacy: .public)")
            filing = nil
            madeThings = nil
        }
        // The chat may have moved to another Notebook while the reads ran.
        guard notebookSourceScopeID == notebookID else { return }
        notebookImportFiling = filing
        madeThingFiling = madeThings
    }

    /// Pin the Notebook-shaped arguments of a Notebook-chat app tool to *this*
    /// Notebook before the call reaches MCP.
    ///
    /// This is aim correction, not a boundary. A Notebook focuses a chat; it does
    /// not wall off the rest of the learner's own library, so a search the model
    /// did not scope itself stays library-wide and reads of what it finds are
    /// unrestricted. What is corrected here is a Notebook id the model may have
    /// guessed: an explicit inside-the-Notebook or not-yet-in-the-Notebook search,
    /// and the Notebook tools, always mean the Notebook this chat is attached to.
    func notebookScopedArguments(
        toolName: String,
        arguments: [String: Any]
    ) -> [String: Any] {
        guard let notebookSourceScopeID else { return arguments }
        var scoped = arguments
        switch toolName {
        case "search_sources_semantic":
            if Self.nonEmptyTrimmed(arguments["exclude_notebook_id"] as? String) != nil {
                scoped["exclude_notebook_id"] = notebookSourceScopeID
                scoped.removeValue(forKey: "notebook_id")
            } else if Self.nonEmptyTrimmed(arguments["notebook_id"] as? String) != nil {
                scoped["notebook_id"] = notebookSourceScopeID
            }
        case "search_sources_keyword":
            // No exclude_notebook_id here: a sweep names this Notebook or none.
            if Self.nonEmptyTrimmed(arguments["notebook_id"] as? String) != nil {
                scoped["notebook_id"] = notebookSourceScopeID
            }
        case "get_notebook_context", "list_notebook_sources", "add_notebook_sources", "set_notebook_source_selection":
            scoped["notebook_id"] = notebookSourceScopeID
        case "import_paper_from_url", "add_source", "add_sources":
            // An import asked for in a Notebook's chat lands in that Notebook
            // too, as the chat's web-citation Add does — when the Notebook can
            // take it: a read-only team's Notebook, or an archived one, would
            // refuse the whole import, so its chat's imports go to the
            // library alone. Filled only when the model left it out: a
            // Notebook the learner named is theirs to choose, and the tool
            // checks it.
            if Self.nonEmptyTrimmed(arguments["notebook_id"] as? String) == nil, notebookImportFiling == .files {
                scoped["notebook_id"] = notebookSourceScopeID
            }
        default:
            break
        }
        if let notebookID = madeThingNotebookID {
            scoped = Self.madeThingArguments(
                toolName: toolName,
                arguments: scoped,
                notebookID: notebookID,
                inTeam: madeThingFiling?.teamID != nil
            )
        }
        return scoped
    }

    /// What a Notebook's chat makes is filed in its notebook
    /// (docs/notebooks-design.md, "Homing"): the notebook argument of a
    /// made-thing tool is filled in when the model left it out, the way an
    /// import's notebook_id is. A notebook the model named, or the learner
    /// did, is theirs to choose, and the tool checks it. Only a new record is
    /// filed: an update of a site or animation keeps where it lives, and a
    /// video of a source or a course module rides that and is not filed. A
    /// picture the chat draws is filed by the chat's own tool
    /// (`generateChatImage`). A team's notebook (`inTeam`) files no course:
    /// a course is made in My Library.
    static func madeThingArguments(
        toolName: String,
        arguments: [String: Any],
        notebookID: String,
        inTeam: Bool = false
    ) -> [String: Any] {
        func absent(_ key: String) -> Bool { nonEmptyTrimmed(arguments[key] as? String) == nil }
        func noLinks(_ key: String) -> Bool {
            ((arguments[key] as? [Any]) ?? []).allSatisfy { nonEmptyTrimmed($0 as? String) == nil }
        }
        var filled = arguments
        switch toolName {
        case "create_doc", "link_page", "link_google_doc":
            if absent("home_notebook_id"), noLinks("notebook_ids") { filled["home_notebook_id"] = notebookID }
        case "save_site":
            if absent("site"), absent("home_notebook_id"), noLinks("notebook_ids") { filled["home_notebook_id"] = notebookID }
        case "save_animation":
            if absent("animation"), absent("home_notebook_id"), noLinks("notebook_ids") { filled["home_notebook_id"] = notebookID }
        case "generate_course", "create_course", "import_youtube_playlist", "import_teachable_course":
            if !inTeam, absent("notebook_id") { filled["notebook_id"] = notebookID }
        case "create_learning_goal":
            if absent("notebook_id") { filled["notebook_id"] = notebookID }
        case "generate_explainer_video":
            if absent("notebook_id"), absent("source_id"), absent("lecture_id") { filled["notebook_id"] = notebookID }
        case "create_idea":
            let links = (arguments["links"] as? [[String: Any]]) ?? []
            let filedAlready = links.contains { link in
                let kind = (link["kind"] as? String)?.lowercased()
                return kind == "notebook" || kind == "goal"
            }
            if !filedAlready {
                filled["links"] = links + [["kind": "notebook", "target_id": notebookID]]
            }
        default:
            break
        }
        return filled
    }

    /// Native tool definitions for this session: the internal source-retrieval
    /// and Notebook-notes tools when their surfaces are active, plus the ForeverLM app
    /// tools this prompt kind exposes.
    func nativeToolSpecs(webSearch: WebSearchAccess = .unavailable) -> [AIToolSpec] {
        var specs: [AIToolSpec] = []

        if !activeSourceIDs.isEmpty, !sourceManifest.isEmpty {
            specs.append(AIToolSpec(
                name: "retrieve_sources",
                description: "Retrieve focused passages (mode \"focused\", the default) or page through a source from beginning to end (mode \"full\"). Full mode returns a continuation cursor when more text remains; pass it back to read the next page. If cursor is omitted, ForeverLM automatically continues after the last full-mode page read in this session instead of repeating it. The attached source text already in context is primary; retrieve only what is missing. Prefer source_ids when the relevant sources are clear from the attached source catalog; use query to let ForeverLM pick relevant attached sources. It reads only the catalog: for any other library source, call search_sources_keyword with its id in source_ids for passages, or get_source_content for its whole text.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_ids": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "IDs of attached sources to retrieve, from the attached source catalog. An id outside the catalog is not read here; use search_sources_keyword with source_ids for it."
                        ] as [String: Any],
                        "query": [
                            "type": "string",
                            "description": "What to find in the attached sources."
                        ],
                        "reason": [
                            "type": "string",
                            "description": "Why this context is needed."
                        ],
                        "max_sources": [
                            "type": "integer",
                            "description": "Maximum sources to retrieve (1-\(sourceRetrievalMaxSources))."
                        ],
                        "mode": [
                            "type": "string",
                            "enum": ["focused", "full"],
                            "description": "focused excerpts (default) or a page in a complete start-to-finish source read."
                        ] as [String: Any],
                        "cursor": [
                            "type": "integer",
                            "minimum": 0,
                            "description": "Full mode only. Pass the next_cursor returned by the previous page. Omit to continue automatically; pass 0 to restart from the beginning."
                        ] as [String: Any],
                    ] as [String: Any],
                ]
            ))
        }

        // The picture tools take any source in the library, attached or not,
        // so they are on offer in every chat: a learner who asks about a paper
        // a search just found gets its figure from the library's own PDF. For
        // example "highlight figure 2a in that paper" ended on
        // pmc.ncbi.nlm.nih.gov in the browser because the paper was in the
        // library but not in this chat, both tools refused its ID as "not
        // attached", and the model went and fetched the publisher's page.
        specs.append(AIToolSpec(
            name: "inspect_paper_figure",
            description: "Inspect a figure from a research paper in the learner's library using ForeverLM's vision analysis, and show the learner the original figure: the paper is opened in the Reader beside this chat, if it is not open there already, and the figure — or the panel asked for — is scrolled to and outlined on its page there, with no picture returned; only a chat with no Reader beside it (a chat in its own window) gets a Markdown image of the figure, cropped to it. Call this whenever the learner asks what a figure, graph, diagram, or labelled subfigure shows. Use the paper's source_id — from the attached catalog or from a search_sources_semantic result; the paper does not have to be attached to this chat — and the printed label such as Figure 2 or Fig. 3. A paper in the library is always shown from its own PDF: never open the publisher's page in the browser or search the web for a figure of a library paper. Pass panel_label to zoom in on one subfigure: the returned picture is then cropped to that panel alone and the explanation is that panel's, so going through a figure panel by panel is one call per panel. When the result carries a Markdown image line, include it exactly in the final answer so the learner sees the actual paper figure; when it says the figure is outlined in the Reader, refer to it there and add no picture.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "source_id": [
                        "type": "string",
                        "description": "Paper source ID, from the attached catalog or a search result. The paper need not be attached to this chat."
                    ],
                    "figure_label": [
                        "type": "string",
                        "description": "Printed figure label, for example Figure 2."
                    ],
                    "panel_label": [
                        "type": "string",
                        "description": "Optional subfigure label, for example b or A. When given, the picture is cropped to that panel alone (zoomed in) and the explanation is that panel's."
                    ],
                ] as [String: Any],
                "required": ["source_id", "figure_label"],
            ]
        ))
        specs.append(AIToolSpec(
            name: "show_source_image",
            description: "Show a picture from a source in the learner's library in the answer — attached to this chat or found by a search; the source need not be attached: a figure, diagram, photo, or illustration from a book chapter, paper, or article, or a slide from a video or meeting recording. Returns one Markdown image line per matching picture; include those lines verbatim, each on its own line, where the picture belongs in the reply, and the learner sees the original picture there and can copy or drag it. Pass query with the printed figure label (Figure 3-4) or caption words to find one picture; pass page for a PDF page an earlier listing named, never a guessed number; pass neither to list the source's captioned pictures. Only pages that actually carry a picture are shown, so a page of prose and a paper's title page are refused: list the pictures first when you do not know which page holds the one you mean. For a video or recording the pictures are its slides, each listed with the stretch of the talk it was on screen for and the words spoken meanwhile: pass query with words from what the slide shows or what was said over it, or slide with a slide number from an earlier listing; a video whose slides have not been captured yet is captured first, which can take a minute. To show any moment of a video, slide or not, pass at with the time: the frame on screen then is captured from the video and returned to you as an image, and crop zooms in on part of it. Call it whenever the learner asks to see, show, or display a figure, picture, or slide, or asks what one looks like.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "source_id": [
                        "type": "string",
                        "description": "Source ID from the attached catalog or from a search result; the source need not be attached to this chat."
                    ],
                    "query": [
                        "type": "string",
                        "description": "Figure label or caption words to match, for example Figure 3-4 or lactate dehydrogenase."
                    ],
                    "page": [
                        "type": "integer",
                        "minimum": 1,
                        "description": "PDF sources only: show this one-based page."
                    ],
                    "slide": [
                        "type": "integer",
                        "minimum": 1,
                        "description": "Video and recording sources only: show this slide, by the number an earlier listing gave it."
                    ],
                    "at": [
                        "type": "string",
                        "description": "Video and recording sources only: capture and show the frame on screen at this time — seconds (265) or a clock reading (4:25, 1:02:03). Any moment works, not only captured slides: use it for a diagram being drawn, an animation, or a time the transcript names."
                    ],
                    "crop": [
                        "type": "object",
                        "description": "Zoom in on part of one slide or frame: fractions of the picture from its top-left corner, each between 0 and 1. Look at the uncropped picture first, then crop to the part that matters.",
                        "properties": [
                            "x": ["type": "number"],
                            "y": ["type": "number"],
                            "width": ["type": "number"],
                            "height": ["type": "number"],
                        ] as [String: Any],
                        "required": ["x", "y", "width", "height"],
                    ] as [String: Any],
                ] as [String: Any],
                "required": ["source_id"],
            ]
        ))
        if !activeSourceIDs.isEmpty, !sourceManifest.isEmpty {
            // The reader's "Show slides" button, callable from the chat. Capture
            // is the slow, deliberate step (it streams the video for frames), so
            // it has a name of its own the model can announce and the learner
            // can see running; showing a captured slide is show_source_image.
            specs.append(AIToolSpec(
                name: "extract_video_slides",
                description: "Capture the slides of an attached YouTube video or meeting recording — the reader's \"Show slides\" button. Slides are never captured at ingest: this reads the video's frames (storyboards for YouTube, the recording file for a meeting), keeps one frame per distinct slide with the stretch of the talk it was on screen, and writes them into the source so the reader and show_source_image can show them. Idempotent: a source whose slides are already captured just lists them. Returns the slide listing with a Markdown image line per slide; include a line verbatim, on its own line, wherever a slide belongs in the reply. Call it when the learner asks to extract, capture, pull, or find the slides of a video, or before show_source_image when you know the slides have not been captured; show_source_image captures on its own when asked for a slide of an uncaptured video, so a plain \"show me the slide about X\" needs only that call. Can take a minute or more on a long talk.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": [
                            "type": "string",
                            "description": "Attached video or meeting-recording source ID from the catalog."
                        ],
                    ] as [String: Any],
                    "required": ["source_id"],
                ]
            ))
        }

        // The review plan beside the composer (`ChatReviewPlan`).
        if offersReviewPlanTool {
            specs.append(reviewPlanToolSpec)
        }

        // The walkthrough's focus, callable by the tutor: the Reader opens
        // beside the chat and scrolls to and outlines what the reply is about,
        // the way a played step does (walkthrough-design.md, "Focus is a chat
        // tool"). Like the picture tools it takes any source in the library,
        // so it rides every chat a pane shows: "explain the key
        // points and walk through the figures" of a paper a search had just
        // found would leave the Reader shut if the tool came only with an
        // attached source (product owner: "from the chat it should be able to
        // open the reader and show what it means"). A manager no pane shows
        // has no Reader to point, so it is not offered there.
        if walkthroughFocusHandler != nil {
            specs.append(AIToolSpec(
                name: "focus_source_anchor",
                description: "Open a paper, book chapter, article, meeting, podcast or video from the learner's library in the Reader beside this chat and point at one place in it while you explain: a figure (outlined on its PDF page), one panel of a figure (outlined alone; a chat with no Reader beside it gets a Markdown image line showing it enlarged instead), a passage copied from the source's text (outlined on the page, or scrolled to and flashed when the source is shown as text, as a meeting's notes or a podcast's transcript are), or a page. A video is pointed at by a moment — at, or a passage copied from its transcript — and its player is paused there. The source need not be attached to this chat: take its source_id from the attached catalog, a search result or list_open_panes. Call it whenever your reply explains what a source says — its key points, a figure, a panel, a passage — pointing first and then explaining what is there, so the learner reads along in the source itself. The Reader shows one place at a time and is left on the last place a reply points at, so when the learner asks you to go through a source or walk through its figures, take one place per reply — point at it, explain it, and end by offering the next. A reply that covers several places, such as an overview of the key points, points at the one it starts with and cites the others with their excerpt links, which open the Reader there when clicked. To explain what a figure shows, inspect_paper_figure outlines it the same way and adds its vision reading; this tool only points, and costs nothing. Every anchor is checked against the source's figure index and text, so use the printed figure label exactly as the source prints it and copy a passage exactly, eight to thirty words in order; an anchor the source does not print is refused.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_id": [
                            "type": "string",
                            "description": "Source ID from the attached catalog, a search result or list_open_panes; the source need not be attached to this chat."
                        ],
                        "figure_label": [
                            "type": "string",
                            "description": "Printed figure label, for example Figure 2 or Fig. 3, or a table's label, for example Table 1, whose caption is outlined."
                        ],
                        "panel_label": [
                            "type": "string",
                            "description": "Optional panel letter within the figure, for example b or A; the panel is outlined alone, and shown enlarged in the reply when the Reader is not already showing it."
                        ],
                        "passage": [
                            "type": "string",
                            "description": "Eight to thirty of the source's own words, copied exactly and in order, to outline on the page or scroll to."
                        ],
                        "page_number": [
                            "type": "integer",
                            "minimum": 1,
                            "description": "PDF sources only: the one-based page to show when no figure or passage names the place."
                        ],
                        "at": [
                            "type": "string",
                            "description": "Videos only: the moment to show, in seconds (973) or a clock reading (16:13, 1:02:03), as a transcript's [mm:ss] marker gives it."
                        ],
                    ] as [String: Any],
                    "required": ["source_id"],
                ]
            ))
        }

        // Drawing needs no attached source: the picture comes from the prompt.
        // Present in every chat so "make me an illustration for this" works
        // wherever it is asked; the description carries the spending rule.
        specs.append(AIToolSpec(
            name: "generate_image",
            description: "Draw a new picture with ForeverLM's image model and show it in the answer: an illustration, visual metaphor, cover image, or diagram concept the learner asks for. Returns one Markdown image line; include it verbatim, on its own line, where the picture belongs in the reply, and the learner sees the picture there and can copy or drag it out of the chat. Write prompt as a complete description of the picture — subject, composition, style, mood, and whether it should contain any text — rather than relaying the learner's words; a few sentences is right. Give a new picture a title too: the few words it is listed under in its notebook's Studio. Call it only when the learner asks for an image to be generated, drawn, created, or illustrated, or when this chat's instructions tell you to draw, because each call is billed to their OpenRouter key, and never to show a picture that already exists in a source — that is show_source_image.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "prompt": [
                        "type": "string",
                        "description": "Full description of the picture to draw."
                    ],
                    "title": [
                        "type": "string",
                        "description": "Required for a new picture: two to six words naming it, as a file is named — \"Forward vs reverse electron transport\", not the prompt's opening. The notebook's Studio lists the picture under it. With revises, omit it to keep the image's title."
                    ],
                    "shape": [
                        "type": "string",
                        "enum": ImageGenerationCatalog.Shape.allCases.map(\.rawValue),
                        "description": "square (default), landscape, or portrait."
                    ] as [String: Any],
                    "quality": [
                        "type": "string",
                        "enum": ImageGenerationCatalog.Quality.allCases.map(\.rawValue),
                        "description": "medium (default); low for a quick draft, high only when the learner asks for the best possible picture."
                    ] as [String: Any],
                    "revises": [
                        "type": "string",
                        "description": "When the learner wants to change a picture already drawn — \"make it bluer\", \"try again without the text\" — the id from that picture's foreverlm://image/generated/<id> line (or from list_generated_images). That picture is sent to the image model to edit, and the result is stored as the next version of the image, so it is listed once rather than as another picture. With revises, write prompt as the edit: what to change and what must stay the same. Omit for a new picture."
                    ] as [String: Any],
                ] as [String: Any],
                "required": ["prompt"],
            ]
        ))

        // The pictures drawn before are kept (each in its notebook's Studio), so
        // "use that picture again" costs nothing: the chat finds its line.
        specs.append(AIToolSpec(
            name: "list_generated_images",
            description: "List the images ForeverLM keeps on this Mac — drawn here, or made elsewhere and saved — most recently changed first, each once at its latest version, with the prompt it was made from and its Markdown image line. Use it when the learner wants an earlier picture again — to show it, reuse it, or change it — and paste that picture's line verbatim, on its own line, instead of drawing it anew; to change it, pass its id to generate_image as revises. Free: nothing is drawn or charged.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "Words the picture's prompt should contain; omit to list the most recent pictures."
                    ],
                    "limit": [
                        "type": "integer",
                        "description": "How many pictures to list; 20 by default, at most 100."
                    ],
                ] as [String: Any],
            ]
        ))

        // What is open beside the chat. A learner who asks about "figure 2D"
        // with a paper in the Reader means that paper, attached or not; the
        // chat sees only what was dragged into it unless it can look.
        if openPanesProvider != nil {
            specs.append(AIToolSpec(
                name: "list_open_panes",
                description: "List what the learner has open in ForeverLM right now: each pane of the window this chat is in, left to right, with the tab on screen and what it shows — the source in the Reader (its source_id, and the PDF page the learner is on), the Doc, Site or animation, the Browser's page, the Activity pane's day — plus tabs behind it that still hold something, and the same for any other ForeverLM window. Call it when the learner refers to something without naming it and neither the on-screen list on their message nor anything attached settles it: \"figure 2D\", \"this paper\", \"this page\", \"what I'm reading\", \"the doc on the right\". What is attached to this chat is what the learner gave it, not necessarily what they have open. A source it lists is in the library, so pass its source_id straight to focus_source_anchor, inspect_paper_figure, show_source_image or get_source_content. Free and instant; it reads the window, nothing else.",
                inputSchema: [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "required": [] as [String],
                ]
            ))
        }

        if synthesisToolContext != nil {
            let markdownSchema: [String: Any] = [
                "type": "object",
                "properties": [
                    "markdown": ["type": "string", "description": "Markdown content."]
                ],
                "required": ["markdown"],
            ]
            specs.append(AIToolSpec(
                name: "add_to_synthesis",
                description: "Append a small, self-contained Markdown note to the learner's Notebook notes. Use only when appending is clearly better than rewriting the notes.",
                inputSchema: markdownSchema
            ))
            specs.append(AIToolSpec(
                name: "replace_synthesis",
                description: "Replace the learner's Notebook notes with complete new Markdown. Preserve useful existing notes unless the learner asks to remove them.",
                inputSchema: markdownSchema
            ))
        }

        if memoryCompanionPlan != nil {
            specs.append(AIToolSpec(
                name: "record_memory_attempt",
                description: "Privately record the learner's just-completed memory attempt before giving final feedback. Never include a memory item ID: ForeverLM owns the active identity. For an existing target, send only the common grading fields. For a first-review target, also send source_id, semantic_target, rubric, and an exact grounded evidence_excerpt from that active source.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "score": [
                            "type": "number",
                            "description": "Model-authored understanding score from 0.0 to 1.0."
                        ],
                        "evaluation": [
                            "type": "string",
                            "description": "Compact explanation of what was understood and what remains missing."
                        ],
                        "retrieval_quality": [
                            "type": "string",
                            "enum": ["independent", "hinted", "not_recalled"],
                            "description": "Whether the learner produced the answer unaided, after help, or could not recall it."
                        ] as [String: Any],
                        "misconception": [
                            "type": "string",
                            "description": "Optional specific misconception to revisit."
                        ],
                        "missing_rubric_elements": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Rubric elements absent or materially wrong; use an empty array when none are missing."
                        ] as [String: Any],
                        "source_id": [
                            "type": "string",
                            "description": "Required only for first review; must be the current attached source."
                        ],
                        "semantic_target": [
                            "type": "string",
                            "description": "Required only for first review: the durable idea or capability, not a question."
                        ],
                        "rubric": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Required only for first review: compact criteria for understanding the semantic target."
                        ] as [String: Any],
                        "evidence_excerpt": [
                            "type": "string",
                            "description": "Required only for first review: an exact passage from source_id grounding the target and rubric."
                        ],
                    ] as [String: Any],
                    "required": [
                        "score",
                        "evaluation",
                        "retrieval_quality",
                        "missing_rubric_elements",
                    ],
                ]
            ))
        }

        if isMemoryReviewSession, !memoryReviewIdeasBySource.isEmpty {
            // The grader and the depth setter are the portable contract's, so
            // the phone's review asks for the same fields in the same words.
            // A review planned by topic grades a topic across its sources; one
            // planned source by source keeps the contour grader it began with.
            specs.append(AIToolSpec(portable: memoryReviewTopics.isEmpty
                ? MemoryReviewTutoring.gradeMemoryContourTool
                : MemoryReviewTutoring.gradeTopicRecallTool))
            specs.append(AIToolSpec(portable: MemoryReviewTutoring.setReviewDepthTool))
        }

        // A teach-back records how each explanation held, silently
        // (docs/morning-routine-design.md, "Recording the explanation").
        if sessionPromptKind == .teachBack, courseQuiz == nil, !activeSourceIDs.isEmpty {
            specs.append(TeachBack.recordToolSpec)
        }

        // "I want to do the Feynman Technique" is said in the notebook's chat:
        // a chat of a Notebook, not one already running it, a quiz or a
        // memory review, can open it.
        if teachBackStarter != nil, notebookSourceScopeID != nil, sessionPromptKind != .teachBack,
           courseQuiz == nil, !isMemoryReviewSession {
            specs.append(AIToolSpec(
                name: TeachBack.toolName,
                description: "Open the Feynman Technique in a new chat in this Notebook, on its ticked sources: the learner says what they know about the Notebook, from memory, and the new chat shows pictures from the sources and asks about the gaps. Call it when the learner says they want to do the Feynman Technique, to explain what they know, or to find the gaps in what they know, about this Notebook. It takes no arguments. The new chat opens when this answer ends, so reply with one short line saying it is opening, and nothing more: no explanation of the technique, and do not ask what they know yourself.",
                inputSchema: [
                    "type": "object",
                    "properties": [:] as [String: Any],
                ]
            ))
        }

        if let courseQuiz {
            specs.append(courseQuiz.toolSpec)
            specs.append(courseQuiz.skipToolSpec)
            if let reading = courseQuiz.readingToolSpec {
                specs.append(reading)
            }
        }

        // Only routes whose engine searches unconditionally need the shim;
        // native engines are attached directly (see WebSearchAccess).
        if webSearch == .onRequest {
            specs.append(AIToolSpec(
                name: "request_web_search",
                description: "Enable live web search for the next assistant step. Call this only after a targeted ForeverLM library search (search_sources_semantic) found no applicable source, or when the learner asks for something the library cannot hold, such as live news or a current price. Never call it before a targeted library lookup — the library holds podcasts, videos, articles, books and papers — or merely to verify a clear library match. The next step receives the provider's web_search tool; use that tool rather than requesting access again.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "One focused web-search query describing the missing external information."
                        ]
                    ],
                    "required": ["query"],
                ]
            ))
        }

        // Reading a page is an app tool on every route: a provider's search
        // returns snippets, and research — or a learner pasting a link — needs
        // the page itself. Fetching runs in the app, so it works the same
        // through OpenRouter, the managed proxy, or a direct key.
        specs.append(AIToolSpec(
            name: "fetch_web_page",
            description: "Read a web page or online PDF as plain text. Use it to read a page a web search surfaced, a link the learner gave, or a reference a page cites — search results are snippets and never enough to support a claim. Returns the title, the final URL, and up to 12,000 characters of readable text; when the page is longer the result ends with the offset to pass for the next part. Pages that need a sign-in or run only in a browser come back as an error; try another source rather than guessing at their content.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "url": [
                        "type": "string",
                        "description": "The http or https URL to read."
                    ],
                    "offset": [
                        "type": "integer",
                        "minimum": 0,
                        "description": "Character offset to continue from, taken from a previous result's continuation note. Omit to start at the beginning."
                    ]
                ],
                "required": ["url"],
            ]
        ))

        // The Browser is the chat's hands on the web: where fetch_web_page
        // reads, these act — behind the learner's sign-ins, with real clicks.
        // The command-the-app chat and Deep Research get them; a graded
        // review stays on its sources.
        if browserAgent != nil, sessionPromptKind == .agent || sessionPromptKind == .deepResearch {
            specs.append(contentsOf: ChatBrowsing.toolSpecs())
        }

        // Code is the chat's calculator: where the Mac can run it, the
        // command-the-app chat and Deep Research get it, and a graded review
        // stays on its sources.
        if codeRunner != nil, sessionPromptKind == .agent || sessionPromptKind == .deepResearch {
            specs.append(ChatCode.toolSpec())
        }

        if appToolExecutor != nil {
            // The chat's own tools win over an MCP tool of the same name. A tool
            // with an MCP twin (inspect_paper_figure) would be sent twice, and
            // Google refuses the whole request as a duplicate function declaration.
            let nativeNames = Set(specs.map(\.name))
            let surface = appToolSurface()
            for tool in surface.sent where !nativeNames.contains(tool.name) {
                specs.append(AIToolSpec(
                    name: tool.name,
                    description: tool.description,
                    inputSchema: Self.schemaObject(fromJSON: tool.inputSchemaJSON)
                ))
            }
            let deferred = surface.deferred.filter { !nativeNames.contains($0.name) }
            if !deferred.isEmpty {
                specs.append(Self.loadAppToolsSpec(deferred: deferred))
            }
        }

        return specs
    }

    private static func schemaObject(fromJSON json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["type": "object"]
        }
        return object
    }
}
