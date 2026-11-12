// Part of ReviewSessionManager: system prompt and instruction assembly.

import Foundation

extension ReviewSessionManager {
    /// The verbatim source text loaded into this chat, the text its tutor
    /// reads with every turn. A side chat over one of the tutor's replies reads
    /// it too (`ChatReplySideChatContext.sourceText`), cut there to the side
    /// chat's own model. Empty until a source's text is loaded.
    var loadedSourceText: String { sourceContext }

    func sourceContextForPrompt() -> String {
        let cleanContext = sourceContext.trimmingCharacters(in: .whitespacesAndNewlines)
        // The budget-reached note rides past the limit on purpose.
        guard cleanContext.count > sourceContextPromptCharacterLimit + Self.sourceBudgetReachedNote.count else {
            return cleanContext
        }

        return String(cleanContext.prefix(sourceContextPromptCharacterLimit))
            + "\n\n[Attached source text truncated in this request to keep the chat within provider limits. Use retrieve_sources for focused passages from omitted text.]"
    }

    func removeProviderMetadataMessages() {
        chatMessages.removeAll { message in
            message.role == .assistant &&
            AIStreamDeltaExtractor.isNonTextRawEvent(message.content)
        }
    }

    /// System prompt split for prompt caching. `stable` carries the instruction
    /// head and the attached source text — the large prefix that stays
    /// byte-identical across turns and is cached with its own breakpoint.
    /// `volatile` carries the per-turn tail (tool results, nudges, the rolling
    /// history digest) that changes between requests; it travels as a separate
    /// unmarked block on providers with block-level cache markers so its churn
    /// never invalidates the cached source text. Providers that take a single
    /// system string get `combined`.
    struct GenerationSystemPrompt {
        var stable: String
        /// The loaded source text, kept apart from `stable` so a request can
        /// cache the instructions and the text separately: Anthropic caches
        /// whole blocks, and text appended to a block that was cached whole
        /// is a different block, so every `retrieve_sources` was a full miss
        /// of everything ahead of the new excerpt. Empty when there is no
        /// source text, or when a retry has folded it back into `stable`.
        var sources: String = ""
        var volatile: String
        /// What providers that take one system string get.
        var combined: String { stable + sources + volatile }
        /// The instructions and the source text together: what `stable` held
        /// before the two were kept apart, for code that reads or shrinks it.
        var stableWithSources: String { stable + sources }

        /// The text a request's source block begins with, which is how a
        /// request's builders tell it from the head and the per-turn tail.
        static let sourceTextHeader = "\nSource text loaded into this chat:\n\n"
    }

    func systemPromptForGeneration(
        allowSourceRetrieval: Bool,
        continuationNudge: String? = nil,
        nativeToolsActive: Bool = false,
        webSearch: WebSearchAccess = .unavailable
    ) -> GenerationSystemPrompt {
        var stable: String
        // A quiz keeps its tutor whatever kind the turn is: a learner's
        // message turns a review into study, and a quiz is neither.
        switch sessionPromptKind {
        case _ where courseQuiz != nil:
            stable = Prompts.courseQuizTutor
        case .review:
            stable = Prompts.reviewTutor
        case .teachBack:
            stable = Prompts.teachBackTutor
        case .study:
            stable = Prompts.studyChat
        case .summarize:
            stable = Prompts.summaryChat
        case .shallowRead:
            stable = Prompts.shallowRead
        case .deepRead:
            stable = Prompts.deepRead
        case .deepResearch:
            stable = deepResearchSystemPrompt
            stable += """

            This is an interactive Deep Research chat. The learner expects the depth of a dedicated research agent: a plan, dozens of searches, pages read in full, and a complete, cited report — not a first page of search results summarized.

            Work in this order.
            1. Plan. Open with a short visible plan: the question as you understand it, the sub-questions or entities you will cover, and the kinds of sources you will look for (papers and conference proceedings, company pages and technical blogs, talks and podcasts, founders' earlier work, filings). Do not ask clarifying questions unless the request is unusable; make reasonable assumptions and state them.
            2. Research every sub-question. Run several web searches per sub-question from different angles, then read the promising pages in full with fetch_web_page. Search results are snippets; never support a claim from a snippet when the page can be read. Follow trails: a paper's references, an author's other work, a company's own publications page. Prefer primary sources. Use the learner's library tools when the library is relevant, but the library never substitutes for the web — the learner is asking for material they do not yet have. Keep going until each sub-question is either answered from evidence or documented as not publicly available. A substantial question typically takes fifteen to forty searches and ten to thirty page reads; do not stop after one pass.
               For every company, lab or product you profile, cover its own channels before relying on what search engines surface: open its website and read the navigation for News, Blog, Research, Publications, Pipeline, Press and Careers pages; follow the links those pages carry to a Substack, Medium or newsletter (often on its own domain, such as company.blog), a GitHub organisation, a YouTube channel, model or dataset releases, and conference posters; search "<name> substack", "<name> blog", "<name> preprint", "site:biorxiv.org <name>", and the founders' names for talks and podcasts; and check registries and filings where they apply — ClinicalTrials.gov, the EU CTR, SEC filings, patents. A company's own technical blog is primary evidence about what it claims and how it checked it; a profile that cites only the homepage and a press release is incomplete, and saying "no publications found" is only allowed after these channels were actually opened. List the channels you checked and found empty, so the reader knows the search was made.
            3. Keep working notes. Early on, create a Doc titled "Research notes: <topic>" with create_doc. After each batch of reading, append the findings for that batch — claim, source URL, and how strong the evidence is — by calling read_doc for the current revision and write_doc with the full updated body. Older tool results are trimmed from your context as the run grows; the notes Doc is your memory, and the report is written from it.
            4. Write the report. Read the notes back with read_doc and write the complete report into a Doc titled "Research: <topic>" (create_doc with the full markdown). Structure: a summary of findings; a section per entity or sub-question; comparison tables where they help; a clear separation of documented fact, strong inference, and speculation; open questions; and a sources section. Cite every claim inline as a markdown link to the page it came from. Length follows the evidence — a broad question earns a long report.
            5. Reply in chat with the key findings in a few paragraphs, name the report Doc so the learner can open it, and say what could not be established. Every web page you searched or read is listed under your reply with an Add button; recommend which ones belong in the learner's library and why.

            When the learner's message carries a What's New request about a passage they marked, its own steps replace steps 3 to 5: the answer is in the chat and its short version goes onto the mark.

            When the learner's message carries a direction search request, call find_directions first; its steps replace steps 4 and 5. Keep the notes Doc as your memory through the run, save what survives with propose_directions, and answer in the chat as those steps say. Write no report Doc unless the learner asks for one: the Directions are the result.
            """
        case .agent:
            stable = Prompts.appAssistant
        }

        // Ahead of every tool and context block: the language and id rules are
        // fixed for the session, so they belong in the cached head, and they
        // apply to every session kind rather than being restated in each
        // template. The id rule comes before the first block that hands the
        // model an id.
        stable += Prompts.responseLanguage
        stable += Prompts.hiddenIDs
        stable += sourceRetrievalToolInstruction(
            allowSourceRetrieval: allowSourceRetrieval,
            nativeToolsActive: nativeToolsActive
        )
        stable += attachedDocsInstruction()
        stable += canvasContextInstruction()
        stable += synthesisToolInstruction(nativeToolsActive: nativeToolsActive)
        stable += appToolInstruction(nativeToolsActive: nativeToolsActive)
        stable += skillCatalogInstruction()
        if let dailyPlanRationale {
            stable += """

            Daily review focus for this session:
            \(dailyPlanRationale)
            """
        }
        if let courseQuiz {
            stable += "\n\n" + courseQuiz.questionList
        }
        stable += memoryCompanionStableInstruction()
        // Kept word for word with `MemoryReviewTutoring.systemPrompt`, so a
        // memory review turn on the phone reads like one on the Mac.
        stable += """

        Response budget: finish every visible chat answer in a single bounded response. Prefer short paragraphs and compact sections over exhaustive dumps. If the learner asks for a very large artifact, produce the useful edited artifact as compact Markdown rather than streaming raw notes or repeated source text.
        """
        // Appended here, after whichever template the kind chose, so a chat
        // whose prompt the learner has customised still gets it. It changes
        // only when a walk starts or stops, so it stays in the cached head.
        if offersFollowUpQuestions {
            stable += """

            \(Prompts.answerShape)

            \(Prompts.chatVisualization)

            \(Prompts.followUpQuestions)
            """
        }

        // What the Notebook exists to answer, ahead of the source text it reads
        // to answer it. Nothing in a turn rewrites these, so they cache; a
        // learner editing them costs one miss, which is the right trade for
        // questions that then ride free on every later turn.
        stable += notebookDefinitionContext()

        // Loaded source text sits at the tail of the stable head, after the
        // catalog and every fixed instruction. That ordering is what lets a
        // newly loaded source be appended without shifting a single cached
        // byte ahead of it.
        var sources = ""
        if !sourceContext.isEmpty {
            sources = GenerationSystemPrompt.sourceTextHeader + sourceContextForPrompt()
        }

        // Everything below changes between requests — keep it out of the
        // stable head so the cached source text survives.
        var volatile = ""
        // "Tomorrow at 7" is only resolvable against a clock the model does not
        // have, and scheduling is the first place that bites. It belongs to the
        // volatile tail precisely because it changes: a date in the stable head
        // would invalidate the cached prefix every midnight.
        volatile += """

        Local date and time on this Mac: \(Self.localClockDescription())
        """
        if !topic.isEmpty {
            volatile += """

            \(sessionTopicLabel): \(topic)
            """
        }
        volatile += workingLogTurnContext()
        volatile += memoryCompanionTurnContext()
        if let courseQuiz {
            // Changes with every grade, so it stays out of the cached head.
            volatile += "\n\n" + courseQuiz.progressNote
        }
        volatile += notebookNotesStateContext()
        // A meeting being recorded on this Mac: what has been said and shown
        // since its stored checkpoint, every turn, outside the cached head.
        volatile += LiveMeetingChatContext.turnContext(forSourceIDs: activeSourceIDs)
        // The grounding rule in the stable head still applies to the learner's
        // sources; this opens a separate lane for live web material.
        switch webSearch {
        case .native where sessionPromptKind == .deepResearch:
            volatile += """

                Deep Research is enabled. The provider's live web-search tool is attached to every step of this turn, and fetch_web_page reads any page in full. Search the web for every substantive question — including after a library lookup, and even when the library covers part of it — read the pages that matter rather than trusting snippets, and keep going across rounds until the plan is covered. Cite only pages you actually read or that the search returned, and never attribute web material to the learner's attached sources — source claims still require loaded source text.
                """
        case .native:
            volatile += """

                Live web search is available: the provider's web_search tool is attached to this step, and only the searches you run are billed. The library comes first, the web second. The learner's library holds podcasts, videos, articles, books and papers, not only the sources attached to this chat, so whenever a question names or implies a particular work — a show or its latest episode, a talk, an author, a paper, a book, a topic — search the library first (search_sources_semantic for a named or described work, filter_sources for the latest or last one of a kind) before doing anything else, even when the wording sounds external or current ("the last Huberman episode", "that Nature paper"). Search the web only if the library has nothing applicable: the library search returned no relevant source, or the learner asks for something the library cannot hold, such as live news, a current price, or material they explicitly want from outside their library. When the library has a match, answer from it and do not also search the web. Cite web pages you rely on through the provider's native citations, and never attribute web material to the learner's attached sources — source claims still require loaded source text.
                """
        case .onRequest:
            volatile += """

                Live web search is available on request. The library comes first, the web second. The learner's library holds podcasts, videos, articles, books and papers, not only the sources attached to this chat, so whenever a question names or implies a particular work — a show or its latest episode, a talk, an author, a paper, a book, a topic — search the library first (search_sources_semantic for a named or described work, filter_sources for the latest or last one of a kind) before doing anything else, even when the wording sounds external or current ("the last Huberman episode", "that Nature paper"). Only if the library has nothing applicable — the library search returned no relevant source, or the learner asks for something the library cannot hold, such as live news, a current price, or material they explicitly want from outside their library — call request_web_search with one focused query; the next assistant step then receives the provider's web_search tool — use it and answer from its citations rather than requesting access again. When the library has a match, answer from it and do not request the web. Cite web pages you rely on as markdown links, and never attribute web material to the learner's attached sources — source claims still require loaded source text.
                """
        case .unavailable:
            volatile += """

                Web search is unavailable on this model route. Continue using the conversation, loaded sources, and ForeverLM app tools; do not claim to have searched the web. If live web information is essential, briefly tell the learner to pick another model in the composer, then help with everything that remains possible.
                """
        }
        if !appToolResultContext.isEmpty {
            volatile += """

            ForeverLM app tool results from this turn:
            <foreverlm_tool_results>
            \(appToolResultContext)
            </foreverlm_tool_results>
            """
        }
        // The block's instruction sits in the cached head, far behind a long
        // chat, and the history never shows a block (each is stripped), so
        // every earlier turn reads as an answer without one. One fixed line
        // near the end keeps it in view.
        if offersFollowUpQuestions {
            volatile += """

            \(Prompts.followUpQuestionsReminder)
            """
        }
        if let continuationNudge, !continuationNudge.isEmpty {
            volatile += """

            \(continuationNudge)
            """
        }

        return GenerationSystemPrompt(stable: stable, sources: sources, volatile: volatile)
    }

    /// The learner's wall clock, spelled out so relative wording in a scheduling
    /// request ("tomorrow", "next Monday", "in the morning") resolves to a real
    /// date and zone rather than a guess. Built per call: a cached formatter
    /// would keep whichever zone was current when the session started.
    private static func localClockDescription() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, yyyy-MM-dd, HH:mm"
        formatter.timeZone = .current
        return "\(formatter.string(from: Date())) (\(TimeZone.current.identifier))"
    }

    /// Stable hidden curriculum for an AI-native memory session. Items describe
    /// what must be understood and the evidence it came from. A card the learner
    /// kept also carries the wording it is asked in (`ask`, the card's front or
    /// the learner's rewording); every other item is worded afresh.
    private func memoryCompanionStableInstruction() -> String {
        guard let plan = memoryCompanionPlan, !plan.targets.isEmpty else { return "" }

        let targets = plan.targets.enumerated().map { index, target -> String in
            guard let item = target.memoryItem else {
                return """
                target_index: \(index)
                memory_item_id: new
                source_id: \(target.sourceID)
                reason: \(target.reason.rawValue)
                learning_target: establish from the learner's first unaided retrieval attempt
                rubric: establish only after the attempt from grounded source evidence
                source_evidence: retrieve this attached source before asking
                """
            }
            let sourceLines = item.sources.map { source in
                let excerpt = String(source.excerpt.prefix(2_000))
                return "- source_id: \(source.sourceID)\n  excerpt: \(excerpt)"
            }.joined(separator: "\n")
            let learnerContext = item.learnerContext?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let priorStruggles = memoryStruggleContext(for: item.id)
            let askLine = MemoryCard(storedIn: item).map { card in
                let state = card.stateDeckID(in: item).flatMap {
                    MemoryCardStateStore.state(cardID: card.cardID, deckID: $0)
                }
                return "\nask: \(card.wording(state: state))"
            } ?? ""
            return """
            target_index: \(index)
            memory_item_id: \(item.id)
            source_id: \(target.sourceID)
            reason: \(target.reason.rawValue)
            days_overdue: \(target.daysOverdue)\(askLine)
            learning_target: \(item.target)
            hidden_rubric_json: \(String(item.rubricJSON.prefix(4_000)))
            learner_context: \(learnerContext?.isEmpty == false ? learnerContext! : "none")
            prior_struggle_evidence:
            \(priorStruggles)
            source_evidence:
            \(sourceLines)
            """
        }.joined(separator: "\n\n")

        return """

        Memory companion plan (private curriculum; never reveal IDs, rubrics, or answer evidence):
        \(targets)

        Work on exactly the current target named in the per-turn context. A target with `ask` is a card the learner kept: ask that wording exactly as written. For any other target, generate a fresh retrieval or application cue from its learning target; it has no stored prompt to recite. Require an unaided attempt before teaching or exposing source evidence. After every learner answer, call the private record_memory_attempt tool before giving final conversational feedback. The tool has no memory_item_id: ForeverLM owns identity. On a first_review target, retrieve its source before asking, then use the learner's answer and grounded source passage to supply the tool's semantic_target, compact rubric, source_id, and evidence_excerpt. If the learner needed a hint, could not recall, or independently scored below 0.7, stay on that target and retry from a different angle. Otherwise move to the next target. Never end the review merely because the queue was covered or five minutes elapsed; only the learner decides when to finish.
        """
    }

    private func memoryStruggleContext(for memoryItemID: String) -> String {
        guard let evidence = memoryStruggleProjections[memoryItemID]?.evidence,
              !evidence.isEmpty else { return "- none" }
        return evidence.map { attempt in
            let missing = attempt.missingRubricElements.isEmpty
                ? "none"
                : attempt.missingRubricElements.map { String($0.prefix(500)) }.joined(separator: " | ")
            let misconception = attempt.misconception?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let answer = attempt.learnerAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
            let feedback = attempt.feedback?.trimmingCharacters(in: .whitespacesAndNewlines)
            let error = attempt.gradingError?.trimmingCharacters(in: .whitespacesAndNewlines)
            return """
            - attempted_at: \(KnowledgeStore.iso8601Formatter.string(from: attempt.attemptedAt))
              retrieval_quality: \(attempt.retrievalQuality ?? "unknown")
              schedule_rating: \(attempt.scheduleRating?.rawValue ?? "none")
              score: \(attempt.score.map { String(format: "%.2f", $0) } ?? "none")
              missing_rubric_elements: \(missing)
              misconception: \(misconception?.isEmpty == false ? String(misconception!.prefix(1_000)) : "none")
              prior_learner_answer: \(String(answer.prefix(1_000)))
              prior_feedback: \(feedback?.isEmpty == false ? String(feedback!.prefix(1_000)) : "none")
              grading_error: \(error?.isEmpty == false ? String(error!.prefix(1_000)) : "none")
            """
        }.joined(separator: "\n")
    }

    /// Volatile cursor over the stable plan. Keeping this out of the cached head
    /// lets retries and target advances avoid invalidating source/prompt caching.
    private func memoryCompanionTurnContext() -> String {
        guard let plan = memoryCompanionPlan, !plan.targets.isEmpty else { return "" }
        let index = min(max(0, currentMemoryTargetIndex), plan.targets.count - 1)
        let target = plan.targets[index]
        let targetID = target.memoryItemID ?? "new"
        let retry = lastMemoryAttemptNeedsRetry
            ? "Retry this same target from a different retrieval or application angle."
            : "Ask or continue this target now."
        return """

        Current memory target (private):
        target_index: \(index)
        memory_item_id: \(targetID)
        source_id: \(target.sourceID)
        \(retry)
        """
    }

    /// The source identity is selected by the app-owned memory cursor. Keeping
    /// this check outside the model prompt makes first-review grounding an
    /// enforceable session invariant rather than a best-effort instruction.
    func currentFirstReviewSourceIDNeedingLoad() -> String? {
        guard let plan = memoryCompanionPlan, !plan.targets.isEmpty else { return nil }
        let index = min(max(0, currentMemoryTargetIndex), plan.targets.count - 1)
        let target = plan.targets[index]
        guard target.reason == .firstReview,
              !loadedSourceIDs.contains(target.sourceID) else { return nil }
        return target.sourceID
    }

    /// The learner's skills by name and description, in the cached head: the
    /// chat reads a skill's instructions with `get_skill` only when a request
    /// matches it, the way Claude loads a SKILL.md (chat-design.md, "Skills").
    /// Empty when the learner has none, or when this chat cannot call
    /// `get_skill` to read one.
    /// The running summary of what the learner is working on (`WorkingLog`),
    /// ahead of every reply so each agent knows the threads in play without
    /// being told. It is background, not a topic: the chat answers what was
    /// asked. Empty while the log holds nothing.
    static let recalledWorkingNoteCount = 6

    private func workingLogTurnContext() -> String {
        let notes = Self.workingNotesBlock(sessionRecalledNotes)
        guard (sessionWorkingLog?.isEmpty == false) || !notes.isEmpty else { return "" }
        let log = sessionWorkingLog.map { "\n<working_log>\n\($0)\n</working_log>" } ?? ""
        return """

        What the learner is working on — the running log and notes ForeverLM keeps in the background from their activity, as a memory, never as a page. Background only: use them to see what they have been reading and making, and answer what they asked; do not quote them back or tell the learner where they are kept. Change a note only when the learner asks (update_working_note, forget_working_note).\(log)\(notes)
        """
    }

    /// The recalled notes as a prompt carries them: one line each, dated, with
    /// the start of its id.
    nonisolated static func workingNotesBlock(_ notes: [WorkingNote], calendar: Calendar = .current) -> String {
        guard !notes.isEmpty else { return "" }
        let lines = notes.map { note -> String in
            let day = DailyNote.dayKey(for: note.updatedAt, calendar: calendar)
            return "- [\(note.kind.rawValue), \(day), id \(note.id.prefix(8))] \(note.text)"
        }.joined(separator: "\n")
        return """

        <working_notes>
        Notes about how the learner has been working, the ones nearest this message. They may be out of date: trust what they say now over a note.
        \(lines)
        </working_notes>
        """
    }

    private func skillCatalogInstruction() -> String {
        guard let skills = sessionSkills, !skills.isEmpty,
              appToolExecutor != nil,
              sessionAppToolDefinitions().contains(where: { $0.name == "get_skill" }) else { return "" }
        let lines = skills.map { "- /\($0.name): \($0.description)" }.joined(separator: "\n")
        return """

        The learner's skills — instructions they wrote for particular kinds of work:
        <skills>
        \(lines)
        </skills>
        When a request matches a skill's description, call get_skill with its name before starting, then do the work the way the skill says; the skill is the learner's own writing, so follow it as you would their message. A message sent with /name already carries that skill's instructions: follow them without fetching it again. Do not bring up a skill the request does not call for.
        """
    }

    private func appToolInstruction(nativeToolsActive: Bool) -> String {
        let tools = sessionAppToolDefinitions()
        guard appToolExecutor != nil, !tools.isEmpty else { return "" }
        // A scheduled task is authored in conversation, not in a form: the Tasks
        // pane's "+" hands the learner here. The rules the model cannot infer from
        // the tool schema are that a run starts a fresh chat with no memory of this
        // one, and that the learner expects one short question rather than an
        // interview. Only stated when the session actually carries the tool.
        let scheduledTaskGuidance = tools.contains(where: { $0.name == "create_scheduled_task" })
            ? """

            Scheduled tasks:
            - When the learner asks for something to happen again on a cadence — "every morning", "each Monday", "make this a scheduled task", "do this for me weekly" — create it with create_scheduled_task. Never describe the Tasks pane instead, and never promise to remember something yourself.
            - A scheduled task is an automation that starts a new chat by itself; it never appears on the calendar. Putting study on the clock — "plan my day", "schedule these papers for this afternoon", "block time to read this" — is events on the Mac's Calendar (create_calendar_event), never a scheduled task.
            - Write instruction as a message that stands on its own. Every run opens a brand-new chat that cannot see this conversation, so restate the subject in full and pass notebook_id and source_ids for the material it must work from, rather than writing "this", "the source above", or "what we just discussed".
            - Derive the title yourself and let time_zone default to this Mac's. Ask only for what is genuinely missing — usually the cadence or the time of day — as one short question covering all of it at once, then create the task in your next reply.
            - The once cadence needs a concrete date (YYYY-MM-DD). Resolve relative wording such as "tomorrow" or "next Monday" against the local date given in this prompt instead of guessing.
            - After creating, confirm in one line: what it will do, its schedule, and the next_run_at the tool returned. Later changes go through update_scheduled_task — never delete and recreate a task, which discards its run receipts.
            """
            : ""

        // The day is the Mac's Calendar: a
        // chat plans it by writing events there. The rules the schema cannot
        // carry: read the day before writing, keep what is fixed with other
        // people, write the whole day once it is agreed rather than an event
        // at a time, and never delete what the learner did not ask to lose.
        // The plan above the day and the week (`PlanQuarter`): the quarter's
        // Page, read with get_plan in the chat's own calls (shown as "Read
        // the plan"), never folded into this prompt, so the learner sees
        // what the chat read (product owner, 2026-11-07: "it should take
        // into account also the quarterly goals … there should be tool calls
        // that are made explicit").
        let planGuidance = tools.contains(where: { $0.name == "get_plan" })
            ? """

            The quarter (a plan Page) and the week (the calendar):
            - The learner plans at three scales, as Cal Newport teaches it: the quarter's bigger picture, objectives, and strategies and habits are a plan Page that get_plan reads (date for another quarter than the present one); the week and the day are the calendar, planned onto it and moved around as they go. What each week is to deliver is written in the quarter's Page, as task lines under its Weeks section.
            - Before planning or reprioritising anything — a quarter, a week, a day, what to work on next, whether to take something on — call get_plan for the quarter's objectives and say in one line which objective the plan you propose serves. A quarter not planned yet is no reason to stop: say so, and offer to plan it.
            - Planning a quarter: read its plan (get_plan with create true), the previous quarter's (date last), list_goals and the working log; plan the whole quarter even when part of it has passed. Propose a whole draft without asking first, revise it in the learner's words, and only once they agree write it into the plan's Page with edit_doc, keeping its headings.
            - Planning a week starts from what it delivers: get_plan for the quarter and what earlier weeks delivered (its Weeks section), get_calendar_events with days 7 for the week, and get_day_activity for how last week went. Propose three to five deliverables, each a thing that exists by the week's end, opening with its objective's name and a colon and ending with the day it is due, then the blocks on its days that deliver them around what is already there. Once agreed, write the deliverables with edit_doc as task lines (- [ ] …) under the week's heading (### Week of November 9) inside the Page's ## Weeks section, and add each block with create_calendar_event. Ticks are the learner's: never tick a line they did not ask you to.
            """
            : ""
        let calendarGuidance = tools.contains(where: { $0.name == "create_calendar_event" })
            ? """

            The day (the Mac's Calendar):
            - The learner's day is their Mac's Calendar: what is on the calendar is the day. When they want to plan a day, block their time, or ask what to focus on, read it first with get_calendar_events (today unless they name a day, and tomorrow once today is underway — by the afternoon, planning means planning the next day); what is already on it for the day and the rest of the week is the week's plan, and get_plan gives the quarter's objectives it serves. Start from those, then the working log (in this prompt, and in full from list_working_notes) and get_day_activity: what the learner has actually been reading and making is what the day should follow. get_schedule and list_goals are secondary: Goals are suggested from that pattern, not the spine of the day.
            - Plan from the clock. The local time in this prompt is the time of this step; get_calendar_events says the rest: each event's when (ended, now or ahead) and today's free_from_now. Add today's new events only into time still ahead of now. Name a day by the relative_day and weekday the tool gives it, never by counting from its date.
            - Planning is an iterative chat, not a form: do not open with a question. Propose a first draft of the whole day as a short list (what is fixed from the calendar, what the day is for from the working log, one line on what you assumed). The learner answers in their own words, and each time you reply with the whole revised list and nothing more, until they say it is right. Once the learner agrees (or asked you to just do it), write every block with create_calendar_event, one call per block, and say in one line what is now on the calendar. Do not write a half-agreed day.
            - An event with has_other_people is a meeting: it stays where it is, and you never move or delete it — the Calendar app is where the learner changes it, so the other people are told. Plan around it. editable says what you may change.
            - Draw work long — 90 to 120 minutes, never under 30. Leave a break when more than two hours remain. Never plan past the end of the learner's day (day_ends). Titles are the learner's own words. Put what the hour is for in notes: the next step, and the foreverlm:// link of the source or Doc it reads.
            - Follow what they are working on, then the Goals. Open with what you see in the working log (threads read often, a topic with no review or writing yet) and offer the next step: solidify it, write about it, or make it a Goal. Where a Goal has a near end date, name it, and name one that has had no time lately rather than letting it slide in silence. Not every block is learning: a call to make, an email to write, someone to reach out to are events too.
            - When they say they are behind, or something took longer: read the day again, then move what is still ahead with update_calendar_event (or delete and re-add what you added for them) so the rest of the day fits — give what is in progress the time it still needs, keep meetings at their times, and carry what no longer fits to tomorrow. Say in one line what moved and why. Never delete an event the learner did not ask you to remove or that you did not add for them.
            - The log (get_day_activity) is what the app saw, not a verdict: read it to plan well, never to tell the learner they failed a block.
            """
            : ""

        // Bouts are the learner's own timer, offered in every chat that has
        // the tools, whether or not the day is being planned.
        let boutGuidance = tools.contains(where: { $0.name == "start_learning_bout" })
            ? """

            Learning bouts (the timer, the write-up, the break):
            - A bout is a stretch of learning with a clock on it. get_learning_bout before anything else; start_learning_bout puts the clock on, with event_id when the day has a calendar event for it.
            - The clock is not a judge. A bout that has run past its end is still running, and nothing — not the timer, not the log — ever ends it. The learner says when they stopped.
            - When a bout ends, ask two questions and only two: what did you learn, and what do you still not understand? Then file their answers with write_up_learning_bout, in their own words. Never write the write-up for them, never smooth it into your own prose, and never skip the second question because they did not volunteer it — what is still unclear is the point of the exercise and the subject of the next bout.
            - The break is earned by the write-up and by nothing else. Once it is filed, offer the break and start it with set_learning_bout_break running=true. Do not offer a break to a bout that has not been written up; the tool will refuse it, and offering it teaches the wrong loop.
            - While a break is running, leave them alone.
            """
            : ""

        // GitHub is read through the plugin and nowhere else. A chat asked
        // to change a site published from a private repository would open
        // github.com in the Browser, meet GitHub's sign-in page and ask the
        // learner to sign in there — the one thing the Browser must never be
        // for: the plugin already reads GitHub as the learner, and a
        // connection that is missing is made in Settings, which the chat
        // offers as a card under the failed step (ChatPluginRequest.SetupNeed).
        let githubGuidance = tools.contains(where: { $0.name == "list_github_repositories" })
            ? """

            GitHub:
            - Read repositories, files, issues, pull requests and commits only with the GitHub tools (list_github_repositories, list_github_files, read_github_file, search_github_code, …). Never open github.com in the Browser to read a repository, and never ask the learner to sign in to GitHub in the Browser pane: the plugin reads GitHub as the learner already, and a github.com page is not how ForeverLM reaches it.
            - When a GitHub tool answers that no GitHub account is connected, that the ForeverLM GitHub App is not installed for a repository's owner, or that the connection must be renewed, stop and say so in one sentence. The chat shows a card under that step that takes the learner to Plugins → GitHub, where they connect GitHub or add the organisation; do not look for another way in, and do not guess at the repository's contents.
            - The connection is read-only: ForeverLM cannot commit, push or open pull requests. A change that must land in a repository is the learner's to make; once it is pushed, save_site with repository reads the new commit.
            """
            : ""

        // Changing a published site must not mean reading every file back and
        // sending every file again — twelve read_site_file calls to change one
        // page. An update carries only the files that change.
        let sitesGuidance = tools.contains(where: { $0.name == "save_site" })
            ? """

            Sites:
            - Make a site with save_site. It is kept in the learner's library and opens in the app; ForeverLM never puts a site on the web. When the learner asks to publish or share one with a link, say so: a public link means making it as a Claude artifact and linking that with link_page.
            - To change a site, read only the files you are changing — read_site_file with the site and a path; without a path it lists the site's files — and call save_site with site and just those files. The other files are kept as they are; never read back or re-send a file you are not changing, and never pass replace_all unless the learner wants the site rebuilt from what you pass.
            - To bring in a change from a GitHub repository, call save_site again with repository (ForeverLM cannot write to GitHub; the change goes into the repository first).
            """
            : ""

        // An animation is code that plays, drawn from what the attached sources
        // say, and saved linked to them (docs/animations-design.md). What the
        // schema cannot carry: that "show me how it works" on a paper is a
        // request for one, that the attached sources' ids are its sources,
        // and that a Doc, a Site or a static figure is not an answer to it.
        let animationsGuidance = tools.contains(where: { $0.name == "save_animation" })
            ? """

            Animations:
            - When the learner wants to see how something works — a pathway, a cycle, a mechanism, a flow, with and without an intervention — or asks to animate, walk through, or watch it, make an animation and save it with save_animation. Never answer with a Doc, a Site, a static figure or a description of what an animation would show.
            - Think before you draw. Write down, for yourself, the one sentence the learner should be able to say after watching; what in the source's figure or text makes that hard to see; what is on the stage and what each motion stands for; the conditions the point turns on; the measured values to show. Then draw exactly that, with the sentence as the page's headline and on its last frame, every control changing something visible, nothing decorative, and the stages named in sentences that say what changed and why it matters. An animation that shows a scene with moving parts but never says its point teaches nothing.
            - Draw what the attached sources describe: read them first (get_source_content or retrieve_sources), then write one HTML document with inline SVG (or Canvas) and JavaScript that plays on load, with play/pause, a scrubber, step labels in words, and a toggle for each condition the sources compare (with and without the drug, wild type and mutant). Put every step where the sources put it — inside the mitochondrion, in the cytosol — and label it there. Use readable text sizes and no network resources; the page runs in a sandbox where localStorage and cookies throw.
            - Pass sources: the attached sources' ids (their source_id in the catalog) the animation is drawn from, so the paper lists it and it opens the paper; pass description: two or three sentences on what it shows and how to read it. Give it a short title. It is kept in the library and never put on the web.
            - Before making a second animation of the same thing, call list_animations with the source's id; to change one, pass its animation_id as animation and only the files that change. After saving, answer with the title in one line; the result card opens it.
            """
            : ""

        // Slack is read live, never remembered. Nothing from Slack is stored in
        // the library — saved Slack threads were retired because a chat that
        // found one believed it had checked the channel — so the one fact the
        // model cannot infer from the schema is that "Slack" always means a
        // read_slack_channel call in this turn, never a library search.
        let slackGuidance = tools.contains(where: { $0.name == "read_slack_channel" || $0.name == "search_slack_messages" })
            ? """

            Slack:
            - When the learner mentions Slack — what was posted, what the channel says, preparing for a session announced there — read Slack live in this turn. To find something specific (an article, a paper, a PDF, a message, who said what), call search_slack_messages with a few distinctive words: it searches every enabled channel as far back as the workspace keeps, in one call. To see what a channel has been discussing, call list_slack_channels, then read_slack_channel on that channel. Do this before, not instead of, searching the library.
            - For the latest, newest or most recent message in a channel — or the latest from a named person — call list_slack_channels, then read_slack_channel on that channel with no since_days: the read opens on the newest messages, widens by itself when the channel has been quiet, and names the newest one in latest_message (threads are listed oldest first, so the last thread is the newest root, and a reply can be newer than every root). Never answer this with search_slack_messages: a from: filter takes an exact @handle, not a display name, and matches nothing otherwise. Find a person's posts in the read by author_name, and name the author as the read gives it; if it gives only a member id, say so rather than guessing who it is.
            - A search hit names its channel_id and thread_ts: call read_slack_thread with them to read the whole thread, which is where the full text, the PDF, or the discussion usually is. Slack search matches whole words, so if a query finds nothing, retry with fewer words (a surname, a journal, part of the title, a URL fragment) before concluding it was never posted.
            - Nothing from Slack is stored in the library, so no search result is ever "what Slack says". Never conclude that nothing was posted without a search_slack_messages or read_slack_channel result from this turn.
            - Links the channel posted are matched against the library for you in library_matches; read a match with get_source_content, and look up a reading named without a link by its DOI or title with search_sources_semantic before calling it external.
            - When the learner wants a file, an article's full text, or a paper's PDF that was posted in Slack, search for it first: search_slack_messages with words from the title, the author, the journal, or the URL, then read_slack_thread on the best hit — a PDF is routinely posted in a different channel than remembered, days after the paper was first mentioned, as a reply to a message that only linked it, and search finds it wherever and whenever it landed. Only if search is unavailable (Slack must be reconnected) fall back to reading every enabled channel with read_slack_channel. Match the file to the paper by the DOI or link in the same thread, or by the file name.
            - A file posted in the channel is listed under files with a download_url that ForeverLM fetches as the learner. When the learner wants a posted PDF in the library, do it in this turn: if the paper already exists (a library_matches entry, or one found by title or DOI), call attach_pdf_to_paper with its source_id and pdf_url set to the download_url; otherwise call import_paper_from_url with url set to the download_url and source_url set to the file's permalink. Never tell the learner to download the file themselves, and never call a Slack attachment unreachable without having tried.
            - If a Slack tool reports that Slack is not connected or a channel is not enabled, say so and point at Plugins → Slack; if search_slack_messages says Slack must be reconnected for search, tell the learner that in one sentence with the connect link and use read_slack_channel for this turn. Do not fall back to guessing from older sources.
            - A library search never answers a question about what is in Slack: search_sources_semantic and search_sources_keyword see only sources saved earlier, so "not indexed" says nothing about the channel. When the learner names a channel, says Slack is connected now, or asks again for a posted file, search or read Slack again in that turn rather than asking which channel or when.
            """
            : ""

        // A paper the chat brings up is one the learner may want. The rule the
        // schema cannot carry: the model resolves the paper's address itself —
        // from the conversation, a web citation, or a web search — instead of
        // sending the learner off to paste a URL it could have found.
        let paperImportGuidance = tools.contains(where: { $0.name == "import_paper_from_url" })
            ? """

            Papers outside the library:
            - When you cite, recommend, or discuss a paper the library does not hold, say so and offer to add it.
            - When the learner asks for it ("add that study", "save that paper"), resolve its DOI or its publisher, arXiv, or PubMed URL yourself — from the conversation, the web citation you used, or a web search — and call import_paper_from_url. Never ask the learner to paste a URL or DOI you can find. If several papers match, name the one you are importing.
            - import_paper_from_url adds a paper even when its PDF is paywalled; report that outcome as the tool describes it rather than as a failure.
            """
            : ""

        // What happens to an import made here follows whether the Notebook
        // takes it (`notebookImportFiling`); unknown says nothing.
        let notebookImportGuidance: String
        switch notebookImportFiling {
        case .files:
            notebookImportGuidance = "- A paper or page you import here at the learner's request (import_paper_from_url, add_source) is filed in this Notebook as well as the library; no add_notebook_sources call is needed for it.\n"
        case .libraryOnly(let refusal):
            notebookImportGuidance = "- This Notebook takes no new sources: \(refusal.reason). A paper or page you import here at the learner's request lands in the library only; say so, and do not offer to add it to the Notebook.\n"
        case nil:
            notebookImportGuidance = ""
        }
        // What the chat makes follows whether its notebook takes new things
        // (`madeThingFiling`); unknown says nothing.
        let madeThingGuidance: String
        switch madeThingFiling {
        case .some(let made) where made.filing == .files:
            let place = made.notebookID == notebookSourceScopeID
                ? "this Notebook"
                : "the Notebook this chat's Goal belongs to (notebook_id \"\(made.notebookID)\")"
            let things = made.teamID == nil
                ? "a Doc, a site or an animation, a course, a Goal or an Idea, a picture, a video"
                : "a Doc, a site or an animation, a Goal or an Idea, a picture, a video"
            let courses = made.teamID == nil ? "" : " A course is made in the learner's own library, in no Notebook: this Notebook is a team's."
            madeThingGuidance = "- What you make here at the learner's request — \(things) — is filed in \(place). Leave home_notebook_id and notebook_id out and ForeverLM fills them in; name another Notebook only when the learner asks for one.\(courses)\n"
        case .some(let made):
            if case .libraryOnly(let refusal) = made.filing {
                madeThingGuidance = "- What you make here is filed in no Notebook: \(made.notebookID == notebookSourceScopeID ? "this Notebook" : "this chat's Notebook") takes nothing new, because \(refusal.reason). Say so when you make something, and do not offer to file it there.\n"
            } else {
                madeThingGuidance = ""
            }
        case nil:
            madeThingGuidance = ""
        }
        let notebookSourceGuidance = notebookSourceScopeID.map { notebookID in
            """

            Notebook sources:
            - This chat is scoped to one Notebook. Its attached source catalog is the working set; use retrieve_sources to read from it, and answer from the Notebook instructions and its sources first.
            - The learner picks which of the Notebook's sources its chats read. This chat's catalog holds the ones ticked when it began; list_notebook_sources marks the rest in_chat false. They are still the Notebook's: leave them out unless the learner asks about one. Tick or untick sources (set_notebook_source_selection) only when the learner asks.
            - The Notebook is a focus, not a wall. The learner's whole library stays readable here: search_sources_semantic and search_sources_keyword search all of it by default, and search_sources_keyword (with source_ids) and get_source_content read any source in it. There is no unlocking step and nothing to ask permission for — it is the learner's own library.
            - Reading a source outside this chat's catalog: \(Self.outsideCatalogReadingRule)
            - So when a request depends on a saved item the Notebook pool does not contain — a dated meeting recording, transcript, notes, a named paper, an earlier session — just look it up and read it. Use the Notebook title, instructions, collection/folder names, source type, and exact local date as discovery context.
            - Notebook membership can change while this chat remains open. If the learner says sources were added, re-read list_notebook_sources or get_notebook_context.
            - To deliberately narrow a search to this Notebook's own sources, pass notebook_id "\(notebookID)". To find sources that are not yet in it, pass exclude_notebook_id "\(notebookID)" instead.
            - Reading something from outside the Notebook does not add it to the Notebook. Call add_notebook_sources only when the learner explicitly chooses sources to bring in.
            \(notebookImportGuidance)\(madeThingGuidance)- Keep the Notebook's subject in view: reach outside it to answer what the learner actually asked, not to volunteer unrelated background.
            """
        } ?? ""

        // A reply is not an action. Asked "open this notebook", a free model
        // answered "I've opened the notebook … it is now active" with no tool
        // call, and the learner stayed in the chat. Opening is
        // named outright because it is the action a model most readily mistakes
        // for words: a link or a get_notebook read feels like showing it.
        let opensThings = tools.contains(where: { $0.name == "open_in_app" })
            ? " Putting something on the learner's screen is an action too: when they ask to open, show, go to or switch to a Notebook, a Page (kind doc), a chat, a source, a quiz or an idea, call open_in_app with its id (list_notebooks finds a Notebook by its title). Asked for a Page next to, beside or alongside the video, paper or book they have open, make or find the Page first, then open it with kind doc and side_by_side true, so the source stays on the left and the Page is on the right. Naming it, linking it or reading it with get_notebook puts nothing on their screen."
            : ""
        // "Show me my flashcards on mitochondria" asks for the card review on
        // screen over some of the cards: the Memory pane has no notebook menu,
        // so a chat narrows the review, by what the cards ask (product owner,
        // 2026-10-13).
        let practisesCards = tools.contains(where: { $0.name == "practice_cards" })
            ? " Asked to show, quiz or practise their cards or flashcards on a topic, a source or a notebook, they want the card review on screen: read list_cards status kept, choose the cards by what each asks, and call practice_cards with their card_ids."
            : ""
        let actionClaimRule = "- Say that you did something in the app — opened, made, added, filed, scheduled, changed or removed it — only when a tool call in this turn did it and its result says so. Otherwise call the tool now, or say plainly that you could not.\(opensThings)\(practisesCards)"

        // Native mode: the tool schemas travel in the request's tool definitions,
        // so the prompt carries only the behavioral rules — no catalog, no
        // <flm_tool_call> format. This also keeps the system prompt stable and
        // cacheable across a turn's tool rounds.
        //
        // These rules are the single home for generic tool-use behavior. Every
        // prompt kind that carries tools receives this block, so the mode prompts
        // in Prompts.swift must not restate them.
        if nativeToolsActive {
            return """

            You have ForeverLM app tools available in this chat — the same tools remote MCP assistants use. Use them when the learner asks you to inspect or change app state, including sources, Notebooks, the Schedule, or review sessions.

            \(notebookSourceGuidance)
            \(paperImportGuidance)
            \(scheduledTaskGuidance)
            \(planGuidance)\(calendarGuidance)
            \(boutGuidance)
            \(slackGuidance)
            \(githubGuidance)
            \(sitesGuidance)
            \(animationsGuidance)

            Tool-use rules:
            - Use app tools for durable app operations instead of describing manual UI steps. The learner is here precisely so they don't have to click through the app.
            - Prefer read-before-write: inspect the relevant current state before planning or mutating it.
            - For Schedule changes, call get_schedule first unless fresh tool output in this turn already includes the needed goal/source/day IDs.
            - For a targeted paper, title, author, keyword, or topic lookup, call search_sources_semantic first — before any web search, and even when the question sounds external ("that Huberman episode on sleep", "that Nature paper"): the library holds podcasts, videos, articles, books and papers beyond what is attached to this chat. If a candidate is plausible but its excerpt is inconclusive, call get_source_content on that candidate before widening the search.
            - search_sources_semantic knows only one kind of date: the day a source was saved to the library. For a request about that day — yesterday's meeting, last week's imports — resolve the concrete local YYYY-MM-DD from the clock in this prompt and pass added_from, added_to, and source_type rather than asking semantic similarity to infer time. A work's own publication year is not that axis and is never an argument: put it in query and leave added_from/added_to out.
            - When the request names a podcast show, YouTube channel, author or person and wants the set ("which Huberman episodes are on mitochondria", "every paper by Martin Picard"), call filter_sources — it lists every match by show, author or title, where a ranked search stops at its limit and lets other shows' episodes take the slots. Read the returned titles, and pass show to search_sources_semantic or search_sources_keyword to find which of those episodes discuss a topic. list_shows gives the exact show and channel names.
            - For "the latest", "the newest", "the last" or "my most recent" source of a kind ("look at my latest YouTube video", "the last Huberman episode"), call filter_sources with source_type (and show, when one is named) and a small limit. It lists newest first by the time each source was added, so its first line is the answer; a ranked search orders by similarity and hands back some other recent source.
            - Call list_sources only when the learner explicitly asks to browse or list the entire library. Never call it as a fallback after a targeted search; its full-library result is intentionally large and does not improve relevance.
            - When search_sources_semantic returns a clear library match, answer from it or inspect it with get_source_content. Do not also search the web unless the learner explicitly requested wider literature. Search the web only when the library has nothing applicable.
            - A paper named in the reference list of a source you are reading proves nothing about whether the library holds it, and the source that cites it is not that paper: never link the citing source as the cited one. Before you tell the learner a paper, book or episode is not in their library, search for it by its title, and by its first author with filter_sources, across the whole library — never only the attached catalog or this Notebook — and say it is absent only when those found nothing.
            - For source-specific mutations, resolve IDs from the attached sources listed in this prompt when the learner refers to what is in this chat, or with search_sources_semantic for a named target. The Notebook highlighted in the app's sidebar is not this chat's context.
            - Do not guess source IDs, goal IDs, notebook IDs, session IDs, or dates. Ask a concise clarification only when required information is genuinely missing or a destructive target is ambiguous — never to get permission for something the learner already asked you to do.
            - Read-only tools (list_*, get_*, search_*) never need confirmation: call them, show the results, and offer any alternatives after the results as a follow-up suggestion, not before them as a blocking question. Mid-task, if one approach comes up short (e.g. discovery finds nothing relevant), try the next obvious tool yourself instead of asking which one to use.
            - For destructive actions such as deleting, archiving, clearing, removing, or overwriting durable content, require explicit user intent in the current request before calling the tool.
            - If a tool result reports an error, surface that error directly and do not pretend the operation succeeded. Never invent IDs, scores, completion status, or source coverage.
            \(actionClaimRule)
            - Never end your reply by announcing an action ("I'll search your library now") — if more tool work is needed to fulfill the learner's request, call the tool instead of narrating it. When you have everything, deliver the concrete results.
            - After tool results arrive, answer the learner with a short summary of what changed or what you found, naming things by their names: no ids, as the Ids rule above says. Do not show raw JSON unless the learner asks.
            - Cite a source from the learner's library by placing its [Title](foreverlm://source/SOURCE_ID) link immediately after the complete claim it supports, after the punctuation. The one exception is a chat opened on a single attached source: that source is never cited, as the rule under the attached source catalog says. The chat renders that link as a numbered citation and lists the full source below the answer. Do not make the linked title part of the sentence's grammar, put a citation link on its own line, or repeat a plain or bold title immediately before the link. Use the exact source id from the tool result; if you do not have one, leave the title unlinked. A standalone source link is appropriate only when you are presenting or recommending the source itself as an item. When the answer lists sources — search results, recommendations, what each source says — start each list item with that source's link and follow it with what the item says: the chat draws that link as the item's title with the source's thumbnail and byline, so do not repeat the title, type or author in the text, and when the item points at one moment or page, put it on that link as you would on a citation. Keep those sources in one list, in the order that answers the question (for a keyword sweep, most mentions first), rather than splitting it under headings by source type, which each byline already shows; group them only when the learner asks for groups. Keep the source's original web URL separate from these in-app links. When the source is a video, podcast, or recording — its text carries [m:ss] or [h:mm:ss] time markers — and the claim rests on a particular passage, put that passage's moment on the link as ?t= in whole seconds, converted exactly from the nearest marker at or before the passage: a passage under [12:34] is cited as [Title](foreverlm://source/SOURCE_ID?t=754). The chat shows the time on the citation and opens the source playing from that moment. Never attach a time the text does not carry, and never put one on a source without time markers. When the source is a text source — a paper, article, book chapter, notes or a document — and the claim rests on a particular passage, give the link a title that is a short excerpt of that passage copied exactly from the source text a tool returned: [Title](foreverlm://source/SOURCE_ID "excerpt copied from the source"). Six to twenty words, on one line, with no double quotation marks inside it and nothing reworded, abbreviated or stitched together from two places. Clicking the citation then opens the source at that passage and marks it for the learner. An excerpt the source does not contain word for word marks nothing, so leave the title off when you cannot copy one; never combine an excerpt with a time. When a text source's content carries [page N] markers — the pages of a PDF, numbered from 1 within that source — also put the page the passage sits under on the link as ?page=N: [Title](foreverlm://source/SOURCE_ID?page=7 "excerpt copied from the source"). The reader then opens that page even when it cannot find the excerpt, and a claim about a whole page or a figure can cite the page with no excerpt at all. Never put a page on a source whose text carries no [page N] markers, and never guess one from a printed page number. The chat shows the page on the citation, as 3 · p. 26, and lists it under the source; following either lands the reader on that page. When your answer names where a passage sits — a printed page, a figure, a section heading — put that citation right after the sentence that names it, so the words the learner reads about the place sit beside the link that opens it; a page citation never stands on its own line as a card while the prose names the place.
            - Never name a tool or tell the learner which tool you would call; say what you did or what they can do in the app.
            - A citation is only ever that [Title](foreverlm://source/SOURCE_ID) link. Never write one as a bare or bracketed number, a 【…】 marker, or an id or JSON such as {"id": "src_…"}, and never copy a bracketed number out of a source's own text — [62] there is that paper's own reference list, not a ForeverLM citation. When you have no id for a source, name it by its title in plain words.
            """
        }

        let catalog = tools.map { tool in
            """
            - \(tool.name): \(tool.description)
              input_schema: \(tool.inputSchemaJSON)
            """
        }
        .joined(separator: "\n")

        return """

        You have the same ForeverLM app tools available inside this Chat that remote MCP assistants can use. Use them when the learner asks you to inspect or change app state, including sources, Notebooks, the Schedule, or review sessions.

        \(notebookSourceGuidance)
        \(scheduledTaskGuidance)
        \(planGuidance)\(calendarGuidance)
        \(boutGuidance)
        \(slackGuidance)
        \(githubGuidance)
        \(sitesGuidance)

        Tool catalog:
        <foreverlm_tools>
        \(catalog)
        </foreverlm_tools>

        Tool-use rules:
        - Use app tools for durable app operations instead of describing manual UI steps.
        - Prefer read-before-write: inspect the relevant current state before planning or mutating it.
        - For Schedule changes, call get_schedule first unless the current turn already includes fresh tool output with the needed goal/source/day IDs.
        - For a targeted paper, title, author, keyword, or topic lookup, call search_sources_semantic first — before any web search, and even when the question sounds external ("that Huberman episode on sleep", "that Nature paper"): the library holds podcasts, videos, articles, books and papers beyond what is attached to this chat. If a candidate is plausible but its excerpt is inconclusive, call get_source_content on that candidate before widening the search.
        - For "the latest", "the newest", "the last" or "my most recent" source of a kind ("look at my latest YouTube video", "the last Huberman episode"), call filter_sources with source_type (and show, when one is named) and a small limit. It lists newest first by the time each source was added, so its first line is the answer; a ranked search orders by similarity and hands back some other recent source.
        - Call list_sources only when the learner explicitly asks to browse or list the entire library. Never call it as a fallback after a targeted search.
        - When search_sources_semantic returns a clear library match, answer from it or inspect it with get_source_content. Do not also search the web unless the learner explicitly requested wider literature.
        - A paper named in the reference list of a source you are reading proves nothing about whether the library holds it, and the source that cites it is not that paper: never link the citing source as the cited one. Before you tell the learner a paper, book or episode is not in their library, search for it by its title, and by its first author with filter_sources, across the whole library — never only the attached catalog or this Notebook — and say it is absent only when those found nothing.
        - For source-specific mutations, resolve IDs from the attached sources listed in this prompt when the learner refers to what is in this chat, or with search_sources_semantic for a named target. The Notebook highlighted in the app's sidebar is not this chat's context.
        - Use exact tool names and input keys from the catalog.
        - Do not guess source IDs, goal IDs, notebook IDs, session IDs, or dates. Ask a concise clarification only when required information is genuinely missing or a destructive target is ambiguous — never to get permission for something the learner already asked you to do.
        - For destructive actions such as deleting, archiving, clearing, removing, or overwriting durable content, require explicit user intent in the current request before calling the tool.
        - If a tool result begins with "Error:", surface that error directly and do not pretend the operation succeeded. Never invent IDs, scores, completion status, or source coverage.
        \(actionClaimRule)
        - After tool results are provided, answer the learner with a short summary of what changed or what you found, naming things by their names: no ids, as the Ids rule above says. Do not show raw JSON unless the learner asks.
        - Cite a source from the learner's library by placing its [Title](foreverlm://source/SOURCE_ID) link immediately after the complete claim it supports, after the punctuation. The one exception is a chat opened on a single attached source: that source is never cited, as the rule under the attached source catalog says. The chat renders that link as a numbered citation and lists the full source below the answer. Do not make the linked title part of the sentence's grammar or put a citation link on its own line. Use the exact source id from the tool result; if you do not have one, leave the title unlinked. A standalone source link is appropriate only when you are presenting or recommending the source itself as an item. When the answer lists sources — search results, recommendations, what each source says — start each list item with that source's link and follow it with what the item says: the chat draws that link as the item's title with the source's thumbnail and byline, so do not repeat the title, type or author in the text, and when the item points at one moment or page, put it on that link as you would on a citation. Keep those sources in one list, in the order that answers the question (for a keyword sweep, most mentions first), rather than splitting it under headings by source type, which each byline already shows; group them only when the learner asks for groups. When the source is a video, podcast, or recording — its text carries [m:ss] or [h:mm:ss] time markers — and the claim rests on a particular passage, put that passage's moment on the link as ?t= in whole seconds, converted exactly from the nearest marker at or before the passage: a passage under [12:34] is cited as [Title](foreverlm://source/SOURCE_ID?t=754). The chat shows the time on the citation and opens the source playing from that moment. Never attach a time the text does not carry, and never put one on a source without time markers. When the source is a text source — a paper, article, book chapter, notes or a document — and the claim rests on a particular passage, give the link a title that is a short excerpt of that passage copied exactly from the source text a tool returned: [Title](foreverlm://source/SOURCE_ID "excerpt copied from the source"). Six to twenty words, on one line, with no double quotation marks inside it and nothing reworded, abbreviated or stitched together from two places. Clicking the citation then opens the source at that passage and marks it for the learner. An excerpt the source does not contain word for word marks nothing, so leave the title off when you cannot copy one; never combine an excerpt with a time. When a text source's content carries [page N] markers — the pages of a PDF, numbered from 1 within that source — also put the page the passage sits under on the link as ?page=N: [Title](foreverlm://source/SOURCE_ID?page=7 "excerpt copied from the source"). The reader then opens that page even when it cannot find the excerpt, and a claim about a whole page or a figure can cite the page with no excerpt at all. Never put a page on a source whose text carries no [page N] markers, and never guess one from a printed page number. The chat shows the page on the citation, as 3 · p. 26, and lists it under the source; following either lands the reader on that page. When your answer names where a passage sits — a printed page, a figure, a section heading — put that citation right after the sentence that names it, so the words the learner reads about the place sit beside the link that opens it; a page citation never stands on its own line as a card while the prose names the place.
        - Never name a tool or tell the learner which tool you would call; say what you did or what they can do in the app.
        - A citation is only ever that [Title](foreverlm://source/SOURCE_ID) link. Never write one as a bare or bracketed number, a 【…】 marker, or an id or JSON such as {"id": "src_…"}, and never copy a bracketed number out of a source's own text — [62] there is that paper's own reference list, not a ForeverLM citation. When you have no id for a source, name it by its title in plain words.

        To call an app tool, emit this block. A brief lead-in sentence before it is allowed, but the block itself must appear in THIS reply:
        <flm_tool_call>{"tool":"foreverlm_tool","name":"TOOL_NAME","arguments":{"key":"value"}}</flm_tool_call>

        Critical: a reply that only describes what you are about to do — "let me...", "I'll create it", "setting that up now", "gathering the sources" — but contains no <flm_tool_call> block ENDS your turn and performs nothing. Never promise an action for a later message. If the learner asked you to do something, emit the tool call for the very first step in this same reply rather than announcing it.

        Equally critical: a reply that asks permission to do what the learner already asked — "do you want me to search your library?", "should I look for sources?", "confirm and I'll proceed" — also ENDS your turn with the request unfinished. Read-only tools (list_*, get_*, search_*) never need confirmation: call them, show the results, and offer any alternatives after the results as a follow-up suggestion, not before them as a blocking question. Mid-task, if one approach comes up short (e.g. discovery finds nothing relevant), try the next obvious tool yourself (e.g. search_sources_semantic) instead of asking which one to use.

        If you need several operations, call one tool at a time — each in its own reply, each carrying its own <flm_tool_call> block — and wait for the result before the next one.

        A read-only lookup is not the finish line. After a get_*/list_*/search_* result comes back, if the learner's request is not yet fulfilled, your very next reply must carry the next <flm_tool_call> — not a sentence like "searching now", "scanning your library", or "finding sources now". Narrating the next step after a tool result ends your turn and performs nothing, exactly like promising it up front. Concretely: if the learner asked you to find a specific source and a list_* or get_* result just returned without it, do not say you are searching — emit the search_sources_semantic call in this reply.
        """
    }

    private func sourceRetrievalToolInstruction(
        allowSourceRetrieval: Bool,
        nativeToolsActive: Bool = false
    ) -> String {
        guard !activeSourceIDs.isEmpty, !sourceManifest.isEmpty else { return "" }

        // Native mode: retrieve_sources is defined in the request's tool
        // definitions; the prompt carries the catalog plus usage guidance only.
        if nativeToolsActive {
            let availability = allowSourceRetrieval
                ? """
                Call retrieve_sources to load what a question needs. Pass source_ids when the catalog makes the right sources obvious; pass query to have ForeverLM rank the attached sources for you. Always pass query even alongside source_ids: it decides which passage inside each source you get, and it lets ForeverLM check your choice against its own ranking. A catalog line shows a title, not contents, so a source whose title does not imply what is in it is easy to miss. When a result contains a source marked "Added by ForeverLM", the ranker placed it above one you asked for — read it with a follow-up retrieve_sources call before you answer, and never treat the short lead as proof of what the source does or does not contain. Use mode "focused" to pull passages matching a query. Use mode "full" only for a start-to-finish read: when a result contains next_cursor, call the same source again with that cursor until the result says the end was reached. Omitting cursor automatically advances from the last full-mode page instead of retrying the same page. You may load up to \(sourceRetrievalMaxSources) focused sources in one call; full mode reads one source at a time.

                Prefer the narrowest thing that answers the question: one chapter rather than the whole book, a focused passage rather than an entire paper.

                \(Self.outsideCatalogReadingRule)

                For research-paper visuals, text retrieval is not visual evidence. Call inspect_paper_figure before explaining a figure or asking a quiz question whose answer depends on a graph, diagram, or labelled panel. Use the returned vision explanation as ground truth. When the result carries a Markdown image line, include it exactly in the visible response so the learner sees the original figure while answering; when it says the figure is outlined in the Reader beside the chat, point the learner at the outlined figure in the paper instead of adding a picture. Both picture tools take any source in the library by its ID, attached or not: a paper that search_sources_semantic just found is shown from the library's own PDF. Never open a publisher's page in the browser or search the web for a figure of a paper the library holds.

                Source text never carries the pictures. When the learner asks to see a figure, diagram, photo, or illustration from a book chapter, article, or paper — or asks whether the source has a picture of something — call show_source_image with that source_id and the figure label or caption words as query, then include the returned Markdown image lines verbatim, each on its own line, where they belong in the answer. Never describe a picture as unavailable, and never redraw it as ASCII art, without having called show_source_image first.

                The same goes for slides. When the learner asks to see the slide of a video or meeting recording that shows something, call show_source_image with that source_id and words from the slide or from what was said over it as query (or slide with a number from an earlier listing); when they ask to extract or capture a video's slides, call extract_video_slides. The "Extracted video slide frames" block in a transcript lists the slides so you can pick one — it is not a way to show them: never write a Markdown image from a path or file name you read there, only from the lines these tools return.

                In a review or quiz, pictures come one at a time, each with its question. Show only the picture the question you are asking is about, directly above that question, then stop and wait for the answer. Never open with a gallery of the pictures the round will use, and never show a picture for a question you have not asked yet. When you grade an answer, the next picture comes with the next question, in the same reply. A Markdown image line a picture tool returned stays valid for the rest of the chat. To show a picture you already listed, put its line in the reply without calling the tool again. So list a video's slides once, then deal them out one question at a time.
                """
                : """
                Source retrieval is unavailable for this response. Answer only from source text already loaded, and say plainly which attached sources you would need to read to answer properly.
                """
            return """

            Attached source catalog:
            <attached_sources>
            \(sourceManifest)
            </attached_sources>

            \(Self.sourceGroundingRule)\(singleSourceCitationRule)

            \(availability)
            """
        }

        let retrievalAvailability = allowSourceRetrieval
            ? """
            You have an internal source retrieval tool available:

            retrieve_sources(source_ids?: [string], query?: string, reason?: string, max_sources?: integer, mode?: "focused" | "full", cursor?: integer)

            Call it to load what a question needs. Prefer source_ids when the catalog makes the right sources obvious; use query when you need ForeverLM to rank the attached sources for you. Always pass query even alongside source_ids: it decides which passage inside each source you get, and it lets ForeverLM check your choice against its own ranking. A catalog line shows a title, not contents, so a source whose title does not imply what is in it is easy to miss. When a result contains a source marked "Added by ForeverLM", the ranker placed it above one you asked for — read it with a follow-up retrieve_sources call before you answer, and never treat the short lead as proof of what the source does or does not contain. Use max_sources between 1 and \(sourceRetrievalMaxSources). Use mode "focused" to pull passages matching a query. Use mode "full" only for a start-to-finish read: it returns next_cursor when another page remains, and you must pass that cursor back until the result says the end was reached. Omitting cursor automatically advances rather than repeating the same page. Full mode reads one source at a time. Prefer the narrowest thing that answers the question: one chapter rather than the whole book, a focused passage rather than an entire paper.

            \(Self.outsideCatalogReadingRule)

            To call the tool, respond with exactly one line and no other text:
            <flm_tool_call>{"tool":"retrieve_sources","source_ids":["SOURCE_ID"],"query":"WHAT_TO_FIND","reason":"WHY_THIS_CONTEXT_IS_NEEDED","max_sources":4}</flm_tool_call>
            <flm_tool_call>{"tool":"retrieve_sources","source_ids":["SOURCE_ID"],"mode":"full","reason":"The learner asked to work through this whole source","max_sources":1}</flm_tool_call>
            """
            : """
            Source retrieval is unavailable for this response. Answer only from source text already loaded, and say plainly which attached sources you would need to read to answer properly.
            """

        return """

        Attached source catalog:
        <attached_sources>
        \(sourceManifest)
        </attached_sources>

        \(Self.sourceGroundingRule)\(singleSourceCitationRule)

        \(retrievalAvailability)
        """
    }

    /// The Docs and Sites the learner attached: what they are, not what they say.
    ///
    /// Sits in the cached head with the source catalog. It changes when a Doc
    /// is attached or detached — exactly when a new prefix is warranted — and
    /// stays byte-identical across every other turn. The body is deliberately
    /// absent: a Doc is edited while the chat is open, so a copy pasted here
    /// would be answering from a document the writer has already moved past.
    func attachedDocsInstruction() -> String {
        guard !contextDocs.isEmpty else { return "" }

        let entries = contextDocs.map { doc -> String in
            let kind = doc.linkedURL.flatMap(LinkedPage.kind(ofURLString:))
            let identity: String
            switch kind {
            case .foreverlmSite:
                identity = "site_id: \(doc.id), site_url: \(doc.linkedURL ?? "")"
            case .claudeArtifact, .codexSite:
                identity = "linked_page_id: \(doc.id), linked_url: \(doc.linkedURL ?? "")"
            case .googleDoc:
                identity = "doc_id: \(doc.id), linked_url: \(doc.linkedURL ?? ""), revision: \(doc.revision)"
            case nil:
                identity = "doc_id: \(doc.id), revision: \(doc.revision)"
            }
            var lines = ["- \"\(doc.title)\" (\(identity))"]
            if !doc.outline.isEmpty {
                lines.append("  Outline:")
                lines.append(contentsOf: doc.outline.map { "    \($0)" })
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")

        // Naming a tool the session does not carry would invite a promise the
        // model cannot keep, so the unavailable case says what is true instead.
        let canReadDocs = appToolExecutor != nil
            && sessionAppToolDefinitions().contains { $0.name == "read_doc" }
        let hasForeverLMSite = contextDocs.contains {
            $0.linkedURL.flatMap(LinkedPage.kind(ofURLString:)) == .foreverlmSite
        }
        let canEditForeverLMSites = appToolExecutor != nil
            && sessionAppToolDefinitions().contains { $0.name == "read_site_file" }
            && sessionAppToolDefinitions().contains { $0.name == "save_site" }

        var accessBlocks: [String] = []
        if canReadDocs {
            accessBlocks.append("""
            Their text is not in this prompt. Read one with read_doc using its doc_id — the whole body, or a character range for a long document — before answering anything that depends on what it says. A title and an outline are not the document; never answer from them alone.
            When the learner asks to integrate, fold in, add, update, revise, correct or fix something in one of these Docs, change that Doc itself: read the region, then call edit_doc with the exact passages to replace or an append, passing the revision back. edit_doc works on a Doc of any length because it carries only what changes; use write_doc only to replace a short Doc outright. Never create a new companion Doc to hold material that belongs in an existing one unless the learner asks for a separate document. If the Doc is published, the edit result says its page is stale — call publish_doc so the page shows the change.
            A linked page is read-only as a Doc. Never call edit_doc or write_doc on a linked_page_id or site_id.
            """)
            // Once, here in the cached head: a page's own standing guidance
            // for whoever reads or changes it, written into the page as a quote.
            accessBlocks.append(Prompts.assistantInstructionsNote)
        } else {
            accessBlocks.append("""
            Their text is not in this prompt and cannot be read in this chat. Say so plainly rather than answering from the titles and outlines above.
            """)
        }
        if hasForeverLMSite {
            accessBlocks.append(canEditForeverLMSites
                ? """
                A ForeverLM Site is edited through its files, not through its rendered text copy. When the learner asks to update, revise, correct or fix an attached site_id, use its site_url with read_site_file to read only the HTML, CSS or JavaScript you are changing (without a path it lists the site's files), then call save_site with that same site and just those files; the other files are kept as they are. Preserve behavior outside the requested change. The selected passage and page route in the learner turn identify what to find; do not create a replacement Doc or a second Site.
                """
                : """
                This chat cannot read or save the attached ForeverLM Site's source files. Say so plainly rather than pretending to update its rendered text copy.
                """)
        }
        let access = accessBlocks.joined(separator: "\n\n")

        return """

        Docs and Sites the learner attached to this chat:
        <attached_docs>
        \(entries)
        </attached_docs>

        \(access)
        """
    }

    /// The canvas the learner is working on and the cards they added to this
    /// chat: what each is and says, so a question about "these" is about them.
    ///
    /// Sits in the cached head after the attached Docs. It changes only when a
    /// card is added or its chip removed, which is a new prefix worth paying
    /// for. The cards' words were taken when they were added: the rest of the
    /// canvas is read live through `get_knowledge_map`, offered only when the
    /// chat carries it.
    func canvasContextInstruction() -> String {
        guard let canvasContext else { return "" }
        let canReadCanvas = appToolExecutor != nil
            && sessionAppToolDefinitions().contains { $0.name == "get_knowledge_map" }
        return canvasContext.instruction(canReadCanvas: canReadCanvas)
    }

    /// A chat opened on one source is a conversation about that source. Every
    /// claim in it is drawn from that source, so a citation after each one
    /// says nothing the learner does not already know -- while the renderer
    /// dutifully draws a `[1]` on every paragraph and the source's card under
    /// the reply. A reply in
    /// such a chat cites only a source it reached for elsewhere in the library.
    private var singleSourceCitationRule: String {
        guard activeSourceIDs.count == 1 else { return "" }
        return """

        This chat is about that one attached source, and the learner knows it. Do not cite it: no [Title](foreverlm://source/…) link after claims drawn from it, in any reply of this chat. Name it in plain words when you need to refer to it. Place a citation link only on a claim taken from a different source you looked up in the library, so the learner can tell which claims came from elsewhere.
        """
    }

    /// How to read a library source that is not in this chat's catalog. A
    /// Notebook chat's agent would otherwise reason it out every turn: that
    /// retrieve_sources reads only the catalog, that get_source_content is a
    /// whole document, and that search_sources_keyword with source_ids gives
    /// passages. Stated once here, it is a rule instead of a deliberation.
    static let outsideCatalogReadingRule = """
    retrieve_sources reads only the sources in this chat's catalog. To read a library source that is not in it (a Notebook source left out of this chat, or anything a search found), call search_sources_keyword with that source's id in source_ids, the words you are looking for as keywords, and snippets_per_source up to 5: it returns the passages where they appear. Call get_source_content, which returns the whole text, only when the learner wants the full source or those passages do not answer the question.
    """

    /// The rule that makes lazy loading safe.
    ///
    /// With no source text in the prompt up front, a model that treats a
    /// recognized title as a substitute for reading will answer fluently from
    /// what it already knows about a paper instead of from the learner's copy
    /// of it — and sound entirely correct doing so. That is the failure this
    /// design has to prevent, so the prohibition is stated directly rather
    /// than left to be inferred from the catalog's shape.
    private static let sourceGroundingRule = """
    The catalog lists what is attached; it does not contain the sources themselves. A catalog line tells you that a source exists, not what it says.

    Do not describe, summarize, compare, quote, or make any factual claim about an attached source whose text is not loaded into this chat. Recognizing a title is not the same as having read it. If you need what a source actually says, load it first — and if you cannot load it, say so rather than answering around it.
    """

    /// Label for the session topic line. The topic itself rides in the volatile
    /// tail because `updateSuggestedSessionTitleIfNeeded` rewrites it while the
    /// first assistant reply.
    private var sessionTopicLabel: String {
        switch sessionPromptKind {
        case .review: return "The review target is"
        case .teachBack: return "The notebook the learner is explaining is"
        case .study: return "The current chat topic is"
        case .summarize: return "The current summary target is"
        case .shallowRead: return "The current shallow-reading target is"
        case .deepRead: return "The current deep-reading target is"
        case .deepResearch: return "The current research question is"
        case .agent: return "The current chat context is"
        }
    }

    /// The Notebook's standing instructions and defining research questions —
    /// what it exists to answer, as opposed to the notes recording what it has
    /// answered so far. Stable across a session: no tool touches them, so they
    /// belong in the cached head where every turn reads them for free.
    private func notebookDefinitionContext() -> String {
        guard let context = synthesisToolContext,
              nonEmptySynthesisText(context.title) != nil else { return "" }
        let instructions = context.instructions.flatMap { nonEmptySynthesisText($0) }
        let questions = context.researchQuestions.compactMap { nonEmptySynthesisText($0) }
        let repository = LearningGoalRecord.normalizedRepository(context.repository)
        let notebookMaterialsMarkdown = nonEmptySynthesisText(context.notebookMaterialsMarkdown)
        guard instructions != nil || !questions.isEmpty || repository != nil || notebookMaterialsMarkdown != nil else {
            return ""
        }

        var block = ""
        if let instructions {
            block += """

            The learner's standing instructions for this Notebook. Follow them for the whole conversation. They are authoritative Notebook context, not merely directions about which sources to load. Answer questions about the Notebook's purpose, recurring workflow, schedule, participants, and other facts stated here directly from these instructions, even when the Notebook has no approved sources. An empty source pool means only that no source-content evidence is available; it does not erase or weaken these instructions. Keep source-content claims separate: load a source before claiming what that source says.
            <notebook_instructions>
            \(instructions)
            </notebook_instructions>
            """
        }
        if !questions.isEmpty {
            let numbered = questions
                .enumerated()
                .map { "\($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
            block += """

            This Notebook's key research questions, in the learner's priority order — the questions it exists to answer. Keep them in view: tie what you cover back to them, and say so plainly when a source answers one, complicates one, or leaves it open.
            <notebook_research_questions>
            \(numbered)
            </notebook_research_questions>
            """
        }
        if let repository {
            block += """

            This Notebook is about the GitHub repository \(repository). Nothing from it is stored in ForeverLM: read it live with the GitHub tools (read_github_file, search_github_code, list_github_files, list_github_issues, get_github_pull_request, list_github_commits, …), passing repository "\(repository)".
            """
        }
        if let notebookMaterialsMarkdown {
            block += """

            Files in the Notebook workspace are authoritative Notebook-native context. The folder structure is entirely user-owned; treat every file's available content as part of the learner's Notebook throughout the conversation. These files belong to this Notebook; they are not global library sources unless the learner explicitly adds them there.
            <notebook_materials>
            \(notebookMaterialsMarkdown)
            </notebook_materials>
            """
        }
        return block
    }

    /// Live Notebook title and notes. Volatile by nature — the model edits the
    /// notes mid-session via add_to_synthesis/replace_synthesis, so this can
    /// change between two turns of the same conversation and must never sit in
    /// the cached prefix.
    private func notebookNotesStateContext() -> String {
        guard let context = synthesisToolContext,
              let notebookTitle = nonEmptySynthesisText(context.title),
              !notebookTitle.isEmpty else { return "" }
        let notebookMarkdown = nonEmptySynthesisText(context.markdown) ?? "(Notebook notes are currently empty.)"
        return """

        Current Notebook title: \(notebookTitle)

        Current Notebook Notes Markdown:
        <current_notebook_notes_markdown>
        \(notebookMarkdown)
        </current_notebook_notes_markdown>
        """
    }

    func synthesisToolInstruction(nativeToolsActive: Bool = false) -> String {
        // Gated on a Notebook existing, but carries none of its contents: the
        // defining attributes travel in the stable head via
        // notebookDefinitionContext(), the title and live notes in the volatile
        // tail via notebookNotesStateContext().
        guard synthesisToolContext.flatMap({ nonEmptySynthesisText($0.title) }) != nil else { return "" }
        let toolAvailability = nativeToolsActive
            ? """
            You can edit this Notebook's notes with add_to_synthesis and replace_synthesis.
            """
            : """
            You have internal Notebook-notes tools available:

            add_to_synthesis(markdown: string)
            replace_synthesis(markdown: string)
            """
        return """

        \(toolAvailability)

        Use these tools when the learner asks to add, save, capture, update, revise, sharpen, fold in, incorporate, reorganize, or iterate on the Notebook notes. Infer this intent semantically; do not rely on fixed phrases. If the learner refers to "this", "that", "what we just figured out", or similar, use the relevant recent conversation and preserve the useful substance.

        The current Notebook title and Notes Markdown appear near the end of this system prompt.

        Prefer Markdown that refines the Notebook notes into clean, skimmable sections:
        - Add source-specific positions under "Source Positions" when a chat clarifies what one source contributes.
        - Add agreements, contradictions, scope differences, and uncertainties under "Comparisons and Tensions".
        - Add polished, source-backed statements under "Claims to Present".
        - Add unresolved issues under "Open Questions".
        - Add an article or talk structure under "Outline" when it helps.
        - Use concise headings, short bullets, and clear labels. Do not dump raw chat notes, transcript fragments, JSON, escaped newline text, or long undifferentiated lists.

        Use replace_synthesis when the learner wants a full iteration, an integrated rewrite, a better argument structure, a comparison of ideas, or a revised thesis. The markdown for replace_synthesis must be the complete new Notes Markdown, preserving useful existing notes unless the learner asks to remove them.

        Use add_to_synthesis only for small additive captures where appending a self-contained note is clearly better than rewriting the artifact.
        \(nativeToolsActive ? "" : """

        To call a tool, respond with exactly one line and no other text. Never explain the tool call, never show the JSON to the learner, and never include prose before or after the tag:
        <flm_tool_call>{"tool":"add_to_synthesis","markdown":"MARKDOWN_TO_APPEND"}</flm_tool_call>
        <flm_tool_call>{"tool":"replace_synthesis","markdown":"COMPLETE_REPLACEMENT_MARKDOWN"}</flm_tool_call>
        """)

        The markdown should be concise but self-contained. If the learner is asking a normal study question or asking you to think through new material, answer normally instead of calling the tool.
        """
    }

    private func nonEmptySynthesisText(_ text: String) -> String? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}
