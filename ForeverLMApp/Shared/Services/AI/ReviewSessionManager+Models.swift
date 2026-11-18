// Part of ReviewSessionManager: the nested model types and transcript text helpers.

import Foundation

extension ReviewSessionManager {
    // MARK: - Models

    struct FoundSource: Identifiable {
        let id: String
        let title: String
        let sourceType: String
        let wordCount: Int?
    }

    struct Message: Identifiable {
        let id: UUID
        let role: Role
        var content: String
        /// When this visible turn was produced. Live messages use their creation
        /// time; resumed messages use the persisted exchange timestamp.
        let createdAt: Date
        /// Model-only context attached to a learner turn, such as a passage they
        /// highlighted in the reader. It must never be rendered, nor persisted
        /// as if the learner typed it — it is stored beside the message, in
        /// `review_exchanges.context_content`, and restored here on resume, so
        /// a chat reopened days later still knows which passage it is about.
        var contextualContent: String?
        var exchangeID: String?
        var exchangeField: ReviewExchangeMessageField?
        /// Provider/model that produced this assistant message. Stamped from the resolved
        /// config when generation starts; resumed sessions fall back to the session's
        /// last-used model. Nil for user messages and app-generated status messages.
        var modelProvider: String?
        var modelID: String?
        /// Set only on `.tool` messages: what the assistant did, for display.
        var toolActivity: ToolActivity?
        /// Set on an assistant turn that plays a walkthrough step: which step
        /// of which record, read off the `WalkthroughStepTurn` line the turn
        /// opens with. The transcript draws the step's anchor chip, panel
        /// letters and animation beside such a row. Nil everywhere else.
        var walkthroughStep: WalkthroughStepTurn.Marker?
        /// The questions the learner could ask next, which the reply wrote as
        /// its `<flm_follow_ups>` tail (`ChatFollowUps`) and the transcript
        /// draws as cards under the newest answer. Set once the turn has
        /// settled, in a chat that offers them. In memory only: nothing
        /// stores or syncs them, so a reopened chat has none.
        var followUpQuestions: [String] = []
        /// Set on the rows a failed turn left when Retry asks it again
        /// (`retryLastGeneration`). They stay on screen as they were, its
        /// steps in the reply's fold with their failures, but the new attempt
        /// is timed, and its pages drawn, from its own rows alone
        /// (`ReviewChatAnswerLayout`): the failed attempt's pages are not the
        /// reply's, which stores none of them. In memory only.
        var isFromFailedAttempt = false

        /// A learner message asked while the tutor's question was still open,
        /// marked as such beside the message. See `ChatSideQuestion`.
        var isSideQuestion: Bool {
            role == .user && ChatSideQuestion.isSideQuestion(contextContent: contextualContent)
        }

        /// A side question the app wrote for the learner: they pressed More
        /// details on a reply. Drawn as a heading, never as their words.
        var isMoreDetailsRequest: Bool {
            role == .user && ChatSideQuestion.isMoreDetails(contextContent: contextualContent)
        }

        init(
            id: UUID = UUID(),
            role: Role,
            content: String,
            createdAt: Date = Date(),
            contextualContent: String? = nil,
            exchangeID: String? = nil,
            exchangeField: ReviewExchangeMessageField? = nil,
            modelProvider: String? = nil,
            modelID: String? = nil,
            toolActivity: ToolActivity? = nil,
            walkthroughStep: WalkthroughStepTurn.Marker? = nil
        ) {
            self.id = id
            self.role = role
            self.content = content
            self.createdAt = createdAt
            self.contextualContent = contextualContent
            self.exchangeID = exchangeID
            self.exchangeField = exchangeField
            self.modelProvider = modelProvider
            self.modelID = modelID
            self.toolActivity = toolActivity
            self.walkthroughStep = walkthroughStep
        }

        /// `.tool` messages are UI-only: they record a tool the assistant ran — or a
        /// harness operation like a context compaction or stream retry — so the
        /// learner can see what happened. They are deliberately excluded from the
        /// provider payload and the saved transcript — the model already receives the
        /// real tool result through `appToolResultContext`, so replaying these would
        /// duplicate it, and harness rows carry no conversational content at all.
        enum Role { case user, assistant, tool }

        /// An operation performed during the assistant's turn, shown in the
        /// transcript as a compact row: a tool invocation, or a harness step
        /// like context compaction, a stream retry, or a continuation.
        struct ToolActivity: Equatable {
            struct SourcePresentation: Equatable {
                let source: StudioArticle

                var id: String { source.id }
                var title: String { source.title }
                var sourceType: String { source.sourceType.rawValue }
            }

            /// One source's share of a `retrieve_sources` result, as the learner
            /// sees it: the library record behind it and the passage the tutor
            /// read, with the model-facing header (id, retrieval reason, query,
            /// paging notes) already stripped and hard line wraps unwrapped.
            struct RetrievedPassage: Equatable, Identifiable {
                let sourceID: String
                let title: String
                let sourceType: String
                /// Resolved when the source is in the attached catalog, which it
                /// is for every requested source; the thumbnail draws from it.
                var presentation: SourcePresentation?
                /// The ranker placed this above a source the tutor asked for.
                let addedByForeverLM: Bool
                let passage: String

                var id: String { sourceID }
            }

            enum State: Equatable { case running, succeeded, failed }

            /// What kind of operation the row records; drives the row's glyph.
            enum Kind: Equatable {
                /// An app/MCP tool the assistant invoked.
                case tool
                /// Context maintenance: tool-result trims and overflow shrinks
                /// that keep the request inside the model's window. (History
                /// folds run silently in the background and have no row.)
                case compaction
                /// An automatic recovery retry (transient stream failure, empty output).
                case retry
                /// Continuing an answer that hit the output-token limit.
                case continuation
                /// Session-level switch to the text tool protocol.
                case fallback
                /// The memory review turning to a source: rendered as a heading
                /// row that names it, never as an activity disclosure.
                case sourceTurn
                /// The reasoning the model showed before it answered or
                /// reached for a tool, folded to a "Thought for 12s" row the
                /// learner can open. Written when the step's answer begins.
                case thinking
            }

            var kind: Kind = .tool
            /// Tool name as called, e.g. `search_sources_semantic`; a stable slug
            /// for harness rows, e.g. `context_overflow_compaction`.
            let toolName: String
            /// Short human-readable rendering of the key arguments, e.g.
            /// `"GDF15 barrier function"` — or, for harness rows, the outcome,
            /// e.g. `"82k → 6k characters"`.
            var detail: String?
            /// Resolved library metadata for source-specific calls. The stable id
            /// remains available for navigation, but is never rendered as the label.
            var sourcePresentation: SourcePresentation? = nil
            var state: State
            /// First lines of the tool's output — or the error behind a harness
            /// step — shown when the row is expanded.
            var resultPreview: String?
            /// Title for harness rows, which have no tool name to phrase.
            /// Completion may rewrite it ("Compacting the cut-off answer" →
            /// "Compacted the cut-off answer").
            var customTitle: String? = nil
            /// Per-source passages behind a successful `retrieve_sources` row,
            /// rendered as source cards instead of the raw model-facing text.
            var retrievedPassages: [RetrievedPassage] = []
            /// The library records behind a successful `get_today_sources` row,
            /// in the order the tool listed them: the day's sources drawn as
            /// banners (picture, title, channel) instead of the transcripts the
            /// model was handed. Filled in once the records load.
            var listedSources: [SourcePresentation] = []
            /// A small picture of the Browser tab behind a `browser_*` step —
            /// the page as it stood when the step settled — so the learner
            /// watches the chat work in the Browser from the transcript. PNG
            /// bytes; presentation only, never persisted.
            var previewImage: Data? = nil
            /// Set only on a `.thinking` row: the reasoning the step showed,
            /// as it streamed, and how long the step ran before its answer
            /// began. Presentation only, never persisted, like the row.
            var reasoning: String = ""
            var thinkingDuration: TimeInterval? = nil
            /// Set only on a `save_card_drafts` row that saved cards: the
            /// cards, which the transcript draws as themselves rather than
            /// as a step (`ReviewChatSavedCardsView`). Rebuilt from the
            /// reply's stored line when the chat is reopened.
            var savedCards: ChatSavedCards? = nil
            /// Set on a page tool's row that wrote a page, and on the row a
            /// reopened chat rebuilds from the reply's stored line
            /// (`ChatWrittenPage.cardRowName`): the page, drawn as a card
            /// under the reply's "Worked for" line.
            var writtenPage: ChatWrittenPage? = nil

            /// Whether this row is a step the chat took in the Browser.
            var isBrowserStep: Bool { kind == .tool && ChatBrowsing.isBrowserTool(toolName) }

            /// Where a turn-line row says the review moved: its source, or a
            /// topic or a chat, which have no library record, so their id
            /// rides in `detail`. Nil for every other row.
            var turnTargetID: String? {
                guard kind == .sourceTurn else { return nil }
                if let id = sourcePresentation?.id { return id }
                return detail
            }

            /// Human-readable verb for the tool, so the row reads as an action rather
            /// than an identifier. Falls back to the raw name for tools without a phrase.
            /// A failed tool call says it failed: a refused `save_site` must
            /// not read "Saved site" beside its warning glyph.
            var title: String {
                if let customTitle { return customTitle }
                guard kind == .tool, state == .failed else { return doneTitle }
                return Self.failedTitle(fromDoneTitle: doneTitle)
            }

            /// "Saved site" → "Couldn't save site": the done phrase's leading
            /// past-tense verb turned back to its base form. A phrase that
            /// does not open with a known verb (a raw tool name) reads
            /// "… failed".
            static func failedTitle(fromDoneTitle done: String) -> String {
                let words = done.split(separator: " ", maxSplits: 1).map(String.init)
                guard let verb = words.first, let base = baseVerbs[verb] else { return "\(done) failed" }
                return words.count > 1 ? "Couldn't \(base) \(words[1])" : "Couldn't \(base)"
            }

            private static let baseVerbs: [String: String] = [
                "Added": "add", "Attached": "attach", "Captured": "capture", "Checked": "check",
                "Cleared": "clear", "Clicked": "click", "Created": "create", "Deleted": "delete", "Edited": "edit",
                "Graded": "grade", "Imported": "import", "Let": "let", "Linked": "link",
                "Listed": "list", "Loaded": "load", "Made": "make", "Marked": "mark",
                "Merged": "merge", "Opened": "open", "Pointed": "point", "Prepared": "prepare",
                "Pressed": "press", "Published": "publish",
                "Queried": "query", "Read": "read", "Ran": "run", "Redrew": "redraw", "Removed": "remove",
                "Reordered": "reorder", "Restored": "restore", "Retrieved": "retrieve", "Saved": "save", "Scheduled": "schedule",
                "Scrolled": "scroll", "Searched": "search", "Set": "set", "Shared": "share", "Split": "split",
                "Started": "start", "Stopped": "stop", "Ticked": "tick", "Took": "take", "Typed": "type",
                "Unlinked": "unlink",
                "Unpublished": "unpublish", "Updated": "update", "Wrote": "write",
            ]

            /// The phrase for a call that ran, e.g. "Saved site".
            private var doneTitle: String {
                switch toolName {
                // Reading / context
                case "search_sources_semantic": return "Searched sources"
                case "get_source_content": return "Read source"
                case "retrieve_sources": return "Retrieved sources"
                case "extract_video_slides": return "Captured slides"
                case "list_sources": return "Listed sources"
                case "filter_sources": return "Listed matching sources"
                case "list_shows": return "Listed shows"
                case "search_sources_keyword": return "Searched source text"
                case "get_app_context": return "Checked app context"
                case "list_open_panes": return "Checked what's open"
                case "get_today_sources": return "Loaded today's sources"
                case "get_schedule": return "Checked the schedule"
                case "search_review_sessions": return "Searched past reviews"
                case "request_web_search": return "Prepared web search"
                case "fetch_web_page": return "Read web page"
                case ChatCode.toolName: return ChatCode.activityTitle
                case _ where ChatBrowsing.isBrowserTool(toolName):
                    return ChatBrowsing.activityTitle(toolName: toolName) ?? toolName
                case "web_search": return "Searched the web"
                case "list_slack_channels": return "Listed Slack channels"
                case "read_slack_channel": return "Read Slack channel"
                case "read_slack_thread": return "Read Slack thread"
                case "search_slack_messages": return "Searched Slack"
                case "get_linear_issue": return "Read Linear issue"
                case "search_linear_issues": return "Searched Linear"
                case "list_linear_issues": return "Listed Linear issues"
                case "list_linear_teams": return "Listed Linear teams"
                case "list_linear_projects": return "Listed Linear projects"
                case "get_linear_project": return "Read Linear project"
                case "list_github_repositories": return "Listed GitHub repositories"
                case "get_github_repository": return "Read GitHub repository"
                case "list_github_files": return "Listed GitHub files"
                case "read_github_file": return "Read GitHub file"
                case "search_github_code": return "Searched GitHub code"
                case "list_github_issues": return "Listed GitHub issues"
                case "get_github_issue": return "Read GitHub issue"
                case "list_github_pull_requests": return "Listed GitHub pull requests"
                case "get_github_pull_request": return "Read GitHub pull request"
                case "list_github_commits": return "Listed GitHub commits"
                case "search_notion": return "Searched Notion"
                case "get_notion_page": return "Read Notion page"
                case "list_notion_databases": return "Listed Notion databases"
                case "get_notion_database": return "Read Notion database"
                case "query_notion_database": return "Queried Notion database"
                case "attach_pdf_to_paper": return "Attached PDF to paper"
                case "attach_supplementary_pdf": return "Added supplementary PDF to paper"
                case "import_paper_from_url": return "Imported paper"

                // Notebooks
                case "create_notebook": return "Created notebook"
                case "update_notebook": return "Updated notebook"
                case "get_notebook", "get_notebook_context": return "Loaded notebook"
                case "list_notebooks": return "Listed notebooks"
                case "add_notebook_sources": return "Added sources to notebook"
                case "list_notebook_sources": return "Listed notebook sources"
                case "reorder_notebook_sources": return "Reordered notebook sources"
                case "set_notebook_source_selection": return "Chose notebook chat sources"
                case "list_notebook_files": return "Listed notebook files"
                case "read_notebook_markdown_file": return "Read notebook document"
                case "write_notebook_markdown_file": return "Saved notebook document"
                case "list_docs": return "Listed pages"
                case "create_doc": return "Created page"
                case "read_doc": return "Read page"
                case "write_doc": return "Saved page"
                case "edit_doc": return "Edited page"
                case "update_doc": return "Updated page"
                case "publish_doc": return "Published page"
                case "adopt_page": return "Made a ForeverLM page"
                case "list_doc_versions": return "Listed page versions"
                case "restore_doc_version": return "Restored a page version"
                case "list_spaces": return "Listed spaces"
                case "update_space": return "Updated spaces"
                case "save_site": return "Saved site"
                case "read_site_file": return "Read site file"
                case "save_animation": return "Saved animation"
                case "list_animations": return "Listed animations"
                case "delete_animation": return "Removed animation"
                case "generate_explainer_video": return "Started video"
                case "generate_walkthrough": return "Wrote walkthrough"
                case "get_walkthrough": return "Read walkthrough"
                case "list_walkthroughs": return "Listed walkthroughs"
                case "save_walkthrough": return "Saved walkthrough"
                case "save_card_drafts": return "Saved cards to check"
                case "draft_cards": return "Started drafting cards"
                case "list_skills": return "Listed skills"
                case "get_skill": return "Read a skill"
                case "save_skill": return "Saved a skill"
                case "delete_skill": return "Removed a skill"
                case "list_working_notes": return "Read notes about your work"
                case "save_working_note": return "Saved a note about your work"
                case "update_working_note": return "Corrected a note about your work"
                case "forget_working_note": return "Forgot a note about your work"
                case "delete_walkthrough": return "Removed walkthrough"
                case "focus_source_anchor": return "Pointed at the source"
                case "update_review_plan": return "Updated the plan"
                case "list_doc_chats": return "Listed page chats"
                case "list_source_highlights": return "Read the highlights"
                case "search_source_highlights": return "Searched highlights"
                case "create_source_highlight": return "Highlighted a passage"
                case "update_source_highlight": return "Wrote on the highlight"
                case "link_doc_passage_to_chat": return "Linked page passage to chat"
                case "unlink_doc_chat": return "Unlinked page chat"
                case "update_notebook_notes", "append_notebook_notes": return "Updated notebook notes"
                case "split_notebook": return "Split notebook"
                case "merge_notebooks": return "Merged notebooks"
                case "create_open_question": return "Added open question"
                case "update_open_question": return "Updated open question"
                case "list_open_questions": return "Listed open questions"

                // Teams and Notebook tasks
                case "list_teams": return "Listed teams"
                case "create_team": return "Created team"
                case "share_with_team": return "Shared with team"
                case "share_notebook": return "Shared notebook"
                case "list_notebook_tasks": return "Listed notebook tasks"
                case "create_notebook_task": return "Created task"
                case "update_notebook_task": return "Updated task"
                case "delete_notebook_task": return "Deleted task"

                // The day: the Mac's Calendar, and the day's log
                case "get_calendar_events": return "Read the calendar"
                case "create_calendar_event": return "Added to the calendar"
                case "update_calendar_event": return "Changed a calendar event"
                case "delete_calendar_event": return "Removed a calendar event"
                case "get_day_activity": return "Read the day's log"
                case "get_plan": return "Read the plan"
                case "list_meeting_action_items": return "Read meeting action items"
                case "set_meeting_action_item_done": return "Ticked an action item"
                case "set_meeting_schedule": return "Set a meeting schedule"

                // Learning bouts
                case "get_learning_bout": return "Read the bout"
                case "start_learning_bout": return "Started a bout"
                case "end_learning_bout": return "Stopped the clock"
                case "write_up_learning_bout": return "Wrote up the bout"
                case "set_learning_bout_break": return "Set the break"
                case "abandon_learning_bout": return "Let a bout go"

                // Goals and the Schedule
                case "create_learning_goal": return "Created goal"
                case "update_learning_goal": return "Updated goal"
                case "reorder_goals": return "Reordered goals"
                case "get_goal": return "Read goal"
                case "list_goals": return "Listed goals"
                case "unschedule_sources": return "Removed sources from schedule"
                case "forget_source_activity": return "Forgot recorded activity"
                case "assign_sources_to_day": return "Scheduled sources"
                case "clear_schedule_day": return "Cleared day"
                case "mark_schedule_day_done": return "Marked day done"
                case "set_source_completion": return "Updated completion"
                case "add_goal_sources": return "Added sources to goal"

                // Directions (docs/directions-design.md)
                case "find_directions": return "Gathered what you have"
                case "search_literature": return "Searched the literature"
                case "propose_directions": return "Saved directions"
                case "list_directions": return "Listed directions"
                case "update_direction": return "Updated direction"
                case "delete_direction": return "Deleted direction"

                // Review sessions
                case "start_review_session": return "Started review"
                case "end_review_session": return "Saved review"
                case "grade_memory_contour", "grade_topic_recall": return "Graded recall"
                case "set_review_depth": return "Set review depth"
                case TeachBack.toolName: return "Opened the \(TeachBack.title)"
                case CourseQuizChatState.gradeToolName: return "Checked answer"
                case CourseQuizChatState.skipToolName: return "Skipped question"
                case CourseQuizChatState.readingToolName: return "Read planned reading"

                default: return toolName
                }
            }
        }

        /// Human-readable model name for the transcript, e.g. "Claude Opus 5".
        var modelDisplayName: String? {
            ReviewSessionRecord.modelDisplayName(modelID: modelID, modelProvider: modelProvider)
        }
    }

    struct SynthesisToolCall: Identifiable, Equatable {
        enum Action: Equatable {
            case append
            case replace
        }

        let id = UUID()
        let action: Action
        let markdown: String
    }

    /// The active Notebook as the prompt sees it. `title` and `markdown` are the
    /// live notes state, which the model rewrites mid-session. `instructions`
    /// (the record's `description`, which the inspector presents as Instructions)
    /// `researchQuestions` and `repository` (the GitHub repository the Notebook
    /// is about, as owner/repo) are the Notebook's defining attributes: only the
    /// learner changes them, and never mid-turn, so they ride in the cached head
    /// while the notes stay in the volatile tail. `notebookMaterialsMarkdown` is
    /// extracted from the Notebook workspace and shares that stable head.
    struct SynthesisToolContext: Equatable {
        let title: String
        let markdown: String
        var instructions: String? = nil
        var researchQuestions: [String] = []
        var repository: String? = nil
        var notebookMaterialsMarkdown = ""
    }

    struct AppToolDefinition {
        let name: String
        let description: String
        let inputSchemaJSON: String
    }

    /// A validated private tool result waiting for the final conversational
    /// feedback. Storage commits this together with the pending review exchange,
    /// so a transcript can never claim an answer was graded while its memory
    /// attempt was lost (or vice versa).
    struct StagedMemoryAttempt {
        /// Non-nil only for first-review intake that may create its item.
        let item: MemoryItem?
        /// Exact curriculum the learner was shown for an existing item. Storage
        /// compares this inside the attempt transaction so a concurrent sync
        /// adoption cannot bind rubric-A evidence to a replacement rubric B.
        let expectedExistingItem: MemoryItem?
        let attempt: MemoryAttempt
        let knowledgeNote: String?
        let shouldAdvance: Bool
    }

    enum InitialPromptMode: String, CaseIterable, Hashable, Identifiable {
        /// General-purpose chat: answer anything, work with attached sources, and drive the app
        /// with the ForeverLM tools. The default — the chat is not limited to review/summarize.
        case assistant
        case shallowRead
        case deepRead
        case deepResearch
        case review
        case summarize

        var id: String { rawValue }

        var title: String {
            switch self {
            case .assistant: return "Chat"
            case .shallowRead: return "Shallow Read"
            case .deepRead: return "Deep Read"
            case .deepResearch: return "Deep Research"
            case .review: return "Review"
            case .summarize: return "Summarize"
            }
        }

        var sessionPromptKindForAutomaticStart: SessionPromptKind {
            switch self {
            case .assistant: return .agent
            case .shallowRead: return .shallowRead
            case .deepRead: return .deepRead
            case .deepResearch: return .deepResearch
            case .review: return .review
            case .summarize: return .summarize
            }
        }

        var sessionPromptKindForUserMessage: SessionPromptKind {
            switch self {
            case .assistant: return .agent
            case .shallowRead: return .shallowRead
            case .deepRead: return .deepRead
            case .deepResearch: return .deepResearch
            case .review: return .study
            case .summarize: return .summarize
            }
        }
    }

    enum SessionPromptKind {
        case review
        case study
        case summarize
        /// Selective source orientation: core claims, ideas, evidence, and caveats.
        case shallowRead
        /// Layered, comprehensive source understanding and critique.
        case deepRead
        /// Deliberately web-enabled chat using the separately configurable Deep Research task.
        case deepResearch
        /// Ephemeral "command the app" agent surface used by the in-app ForeverLM Assistant
        /// window. Agent sessions are not persisted as review records.
        case agent
        /// The Feynman Technique (`TeachBack`): the learner says what they know
        /// of a notebook and the tutor probes and fills in (`Prompts.teachBackTutor`). Kept like
        /// a review, tutor turn by learner turn, and named by the chat's id,
        /// so a learner's message never turns it into study.
        case teachBack
    }

    static func displayableMessageContent(role: Message.Role, content: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // A learner message reads as prose: each attached picture's line
        // becomes a note naming it. The bubble draws the pictures themselves
        // from the raw content; everything that quotes the transcript as text
        // — copies, compacted history, grading — reads this.
        guard role == .assistant else { return AttachedImageReference.textOnly(content) }
        guard let visible = displayableAssistantContentKeepingSourceTurns(content) else { return nil }
        // A turn line is a heading row when the reply was split, and nothing
        // when it was not; it is never prose. A walkthrough step's opening
        // line is the row's chips, never prose either.
        let stripped = WalkthroughStepTurn.stripped(MemoryReviewSourceTurn.stripped(visible))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }

    /// `displayableMessageContent` for an assistant reply, with its
    /// `<flm_source_turn>` lines left in place for the split that turns them
    /// into heading rows.
    static func displayableAssistantContentKeepingSourceTurns(_ content: String) -> String? {
        guard let text = AIStreamDeltaExtractor.text(fromRawDelta: content) else { return nil }
        // A reply saved before its printed source ids were repaired, or still
        // streaming, shows them as citations all the same.
        return visibleAssistantText(from: text).map { ChatSourceIDCitations.linking($0) }
    }

    static func copiedConversationText(from messages: [Message]) -> String {
        var turns: [ConversationTranscriptFormatter.Turn] = []
        var answerMessages: [Message] = []

        func flushAnswer() {
            let content = copiedAnswerText(from: answerMessages)
            if !content.isEmpty {
                turns.append(.init(speaker: .assistant, content: content))
            }
            answerMessages.removeAll(keepingCapacity: true)
        }

        for message in messages {
            if message.role == .user {
                flushAnswer()
                if let content = displayableMessageContent(role: .user, content: message.content) {
                    turns.append(.init(speaker: .user, content: content))
                }
            } else {
                answerMessages.append(message)
            }
        }

        flushAnswer()
        return ConversationTranscriptFormatter.plainText(from: turns)
    }

    /// The same transcript for a chat that is not open in a panel (its sidebar
    /// row, the menu bar's Copy Conversation), read from its saved exchanges:
    /// the learner's words and the replies they were shown, in order. The tool
    /// rows of a live turn are not stored, so they are not in it.
    static func copiedConversationText(fromStored exchanges: [ReviewExchangeRecord]) -> String {
        var turns: [ConversationTranscriptFormatter.Turn] = []
        var lastAssistant: String?

        func appendAssistant(_ text: String?) {
            guard let text,
                  let content = displayableMessageContent(role: .assistant, content: text)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty else { return }
            // A reply stored again as the next question is still the same reply.
            if lastAssistant.map(Self.storedProse) == Self.storedProse(content) { return }
            turns.append(.init(speaker: .assistant, content: content))
            lastAssistant = content
        }

        for exchange in exchanges.sorted(by: { $0.sequenceNumber < $1.sequenceNumber }) {
            let question = exchange.question.trimmingCharacters(in: .whitespacesAndNewlines)
            if question != RealtimeExchangeLedger.openConversationQuestion {
                appendAssistant(question)
            }
            if let answer = exchange.userAnswer,
               let content = displayableMessageContent(role: .user, content: answer) {
                turns.append(.init(speaker: .user, content: content))
            }
            appendAssistant(exchange.evaluation)
        }
        return ConversationTranscriptFormatter.plainText(from: turns)
    }

    /// Clipboard representation of one complete assistant turn. A model answer can
    /// arrive as several text messages separated by tool rows; copying only one of
    /// those messages loses the visible reasoning trail. Keep the compact activity
    /// label and detail, but never copy the expandable result preview or source card.
    static func copiedAnswerText(from messages: [Message]) -> String {
        messages.compactMap { message -> String? in
            if let activity = message.toolActivity {
                // The model's reasoning is how it got to the answer, not the
                // answer; a copy carries what the learner was told.
                if activity.kind == .thinking { return nil }
                let detail = activity.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return detail.isEmpty ? activity.title : "\(activity.title) — \(detail)"
            }

            guard message.role == .assistant,
                  let content = displayableMessageContent(role: .assistant, content: message.content) else {
                return nil
            }
            return content
        }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    /// Verbatim text for a set of sources, ready to fold into `sourceContext`.
    struct LoadedSourceText {
        let text: String
        let shares: [ChatContextBreakdown.SourceShare]
        let loadedIDs: Set<String>

        static let empty = LoadedSourceText(text: "", shares: [], loadedIDs: [])
        var isEmpty: Bool { text.isEmpty }
    }

    struct AppToolCall {
        let name: String
        let arguments: [String: Any]
    }

    /// Outcome of one app-tool invocation. `isError` comes from the tool layer
    /// itself, so failure detection never depends on sniffing message prefixes.
    struct AppToolResult {
        let text: String
        let isError: Bool
        /// Pictures handed to the model with the text, so it sees what it is
        /// showing — a slide, or a frame it captured and may want to crop.
        var images: [AIChatImage] = []
    }

    /// One turn's tally of app-tool refusals, keyed by their wording. There
    /// is still no ceiling on how many calls a turn makes — long commands
    /// chain many — but a refusal that comes back word for word is not
    /// progress: a chat asked to add one compound to a Site once
    /// called save_site, publish_site and read_site_file some sixty times in
    /// fifteen minutes, each refused with the same sentence. Once a refusal
    /// has come back `limit` times, the model is told to stop and explain,
    /// every tool that gave it is withheld for the rest of the turn, and
    /// `limit` withheld calls end the turn with the refusal as its error.
    struct RepeatedToolRefusals {
        static let limit = 3

        private var counts: [String: Int] = [:]
        private var toolsByRefusal: [String: Set<String>] = [:]
        private var blocked: [String: String] = [:]
        private(set) var withheldCalls = 0

        /// The refusal behind the withholding, once `withheldCalls` reaches
        /// `limit`: the turn should end.
        private(set) var exhaustedRefusal: String?

        /// A stand-in result for a call to a withheld tool, counted; nil
        /// when the tool may run.
        mutating func withheldResult(for toolName: String) -> AppToolResult? {
            guard let refusal = blocked[toolName] else { return nil }
            withheldCalls += 1
            if withheldCalls >= Self.limit { exhaustedRefusal = refusal }
            return AppToolResult(
                text: "Error: not run. ForeverLM stopped calling \(toolName) in this turn after the same refusal came back \(Self.limit) times: \(refusal)\nDo not call it again. Tell the learner in plain words what is blocking the request and what they can do about it.",
                isError: true
            )
        }

        /// Records a result that ran (never a withheld stand-in) and returns
        /// the text the model should read: the result itself, with a stop
        /// note when it withholds another tool.
        mutating func record(toolName: String, result: AppToolResult) -> String {
            guard result.isError else { return result.text }
            let key = Self.key(result.text)
            guard !key.isEmpty else { return result.text }
            counts[key, default: 0] += 1
            toolsByRefusal[key, default: []].insert(toolName)
            guard counts[key, default: 0] >= Self.limit else { return result.text }
            let refusal = Self.shown(result.text)
            let newlyBlocked = toolsByRefusal[key, default: []].filter { blocked[$0] == nil }
            guard !newlyBlocked.isEmpty else { return result.text }
            for tool in newlyBlocked { blocked[tool] = refusal }
            return result.text + "\n\nForeverLM: this refusal has now come back \(counts[key, default: 0]) times in this turn, so \(toolsByRefusal[key, default: []].sorted().joined(separator: ", ")) will not be run again until the learner's next message. Stop retrying and do not work around it with other tools. Tell the learner in plain words what is blocking the request and what they can do about it."
        }

        /// The wording a refusal is recognised by: case, spacing and a
        /// leading "Error:" ignored, so a retry with other arguments that is
        /// refused the same way counts as the same refusal.
        static func key(_ text: String) -> String {
            var normalized = text.lowercased()
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if normalized.hasPrefix("error:") {
                normalized = String(normalized.dropFirst("error:".count)).trimmingCharacters(in: .whitespaces)
            }
            return String(normalized.prefix(400))
        }

        /// The error that ends the turn. Not an `AIError`: a refusal's own
        /// words ("… tools are not available …") must never read as the
        /// provider rejecting native tools and replay the turn on the text
        /// protocol (`AINativeToolSupport.isNativeToolRejection`).
        struct Stopped: LocalizedError {
            let refusal: String
            var errorDescription: String? {
                "ForeverLM stopped this reply because the chat kept retrying a tool that refused the same way each time: \(refusal)"
            }
        }

        private static func shown(_ text: String) -> String {
            var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("error:") {
                trimmed = String(trimmed.dropFirst("error:".count)).trimmingCharacters(in: .whitespaces)
            }
            return trimmed.count > 600 ? String(trimmed.prefix(600)) + "…" : trimmed
        }
    }

    /// Composition of the request most recently dispatched to the model,
    /// published once per generation round so the composer's context gauge can
    /// render a live breakdown.
    ///
    /// Components are stored as character counts, never as tokens: the app has
    /// no tokenizer for the models it talks to, so tokens are always derived
    /// through `charactersPerToken`. That divisor starts at the crude
    /// `AIService.approxCharsPerToken` guess and is replaced by the real ratio
    /// as soon as the provider reports what it actually billed for this
    /// request — see `measuredPromptTokens`.
    struct ChatContextBreakdown: Equatable {
        struct SourceShare: Equatable, Identifiable {
            let id: String
            let title: String
            let characters: Int
        }

        var providerName = ""
        var modelID = ""
        /// Nil when no host has published a window for this model. The gauge
        /// then shows what the request carries without a percentage, rather
        /// than dividing by a guess.
        var contextWindowTokens: Int? = nil
        /// System instructions (prompt + tool rules), excluding attached source text.
        var instructionCharacters = 0
        /// Attached source text (inventory + excerpts + retrieved passages).
        var sourceCharacters = 0
        /// Native tool schemas sent with the request.
        var toolCharacters = 0
        /// Conversation turns, including tool results accumulated this turn.
        var conversationCharacters = 0
        /// Volatile system tail: history digest, app tool results, retry nudges.
        var volatileCharacters = 0
        /// Per-source share of `sourceCharacters` as included at attach time.
        var perSource: [SourceShare] = []
        /// When this request was assembled. A usage event only describes this
        /// request if it was recorded after this instant; anything earlier
        /// belongs to a previous round.
        var publishedAt = Date()
        /// Prompt tokens the provider reported for *this* request, once it
        /// completes. Exact — this is the billed number, not a derivation.
        var measuredPromptTokens: Int?
        /// Ratio observed on the previous completed request, so a freshly
        /// dispatched round renders calibrated instead of showing the raw
        /// guess and then snapping when its own usage lands.
        var priorCharactersPerToken: Double?

        var totalCharacters: Int {
            instructionCharacters + sourceCharacters + toolCharacters
                + conversationCharacters + volatileCharacters
        }

        /// Characters counted per token billed. This absorbs both the model's
        /// real tokenization and the request overhead the character counts
        /// can't see (JSON envelopes, message framing, tool-schema encoding),
        /// so it corrects the whole gap rather than just the tokenizer's.
        var charactersPerToken: Double {
            if let measured = measuredPromptTokens, measured > 0, totalCharacters > 0 {
                return Double(totalCharacters) / Double(measured)
            }
            return priorCharactersPerToken ?? Double(AIService.approxCharsPerToken)
        }

        /// True once a provider-reported count backs these numbers, whether
        /// from this request or the one before it. Drives the popover's
        /// "estimates" vs "measured" footnote.
        var isCalibrated: Bool { measuredPromptTokens != nil || priorCharactersPerToken != nil }

        func tokens(_ characters: Int) -> Int {
            guard characters > 0, charactersPerToken > 0 else { return 0 }
            return Int((Double(characters) / charactersPerToken).rounded())
        }

        var instructionTokens: Int { tokens(instructionCharacters) }
        var sourceTokens: Int { tokens(sourceCharacters) }
        var toolTokens: Int { tokens(toolCharacters) }
        var conversationTokens: Int { tokens(conversationCharacters) }
        var volatileTokens: Int { tokens(volatileCharacters) }

        /// The provider's own number when it has one, so the headline total is
        /// exact rather than the sum of five rounded component estimates.
        var usedTokens: Int {
            if let measured = measuredPromptTokens, measured > 0 { return measured }
            return tokens(totalCharacters)
        }
        var freeTokens: Int? { contextWindowTokens.map { max(0, $0 - usedTokens) } }
        var usedFraction: Double {
            guard let contextWindowTokens, contextWindowTokens > 0 else { return 0 }
            return min(1, Double(usedTokens) / Double(contextWindowTokens))
        }
    }
}
