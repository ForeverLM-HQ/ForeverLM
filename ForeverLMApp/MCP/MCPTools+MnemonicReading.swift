#if os(macOS)
import Foundation

// MARK: - Mnemonic readings over MCP
//
// docs/memory-design.md, "Mnemonic reading (2026-10-03)". Four tools: an
// assistant has ForeverLM write a reading's questions
// (`generate_mnemonic_reading`, priced first like every paid maker, the same
// run the Studio's Make starts), saves questions it wrote itself
// (`save_mnemonic_reading`, free, grounded as `save_card_drafts` grounds its
// cards), reads a reading with where each question stands in the learner's
// Memory (`get_mnemonic_reading`), and records an answer as the reading's own
// Forgot and Remembered do (`answer_mnemonic_question`). All four are the
// Mac's: the questions live in a body in its library, and the sources' text
// and the Memory an answer writes are its own. The Docs write tools refuse a
// reading (`refuseMnemonicReadingChange`): its body is its questions, which
// only these tools change.

extension MCPToolRegistry {
    /// The most sources one call reads or saves.
    static let maxMnemonicReadingSources = 200
    /// The most questions one `save_mnemonic_reading` call saves.
    static let maxSavedMnemonicQuestions = 500

    static var mnemonicReadingToolDefs: [MCPToolDef] {
        [
            MCPToolDef(
                name: "generate_mnemonic_reading",
                description: "Make a mnemonic reading in ForeverLM, as the Mnemonic reading tile in a Notebook's Studio and Make Mnemonic Reading in the Reader do: the sources' own stored text read with recall questions set right after the passages they test. A book's chapters in reading order, or any chapter, paper or article. The learner reads it in ForeverLM, answers each question in their head, shows the answer and grades it, and every answered question is kept as a Memory card that comes back in the card review. Name the sources with source_ids in reading order, as list_sources or a search returns them (an id the library does not hold refuses the whole call); or book, a book's book_id or title as list_sources shows it, for all its chapters in order; or notebook_id alone for the Notebook's ticked sources. With notebook_id the reading is filed in that Notebook. density is auto (the default: about one question for every 350 words of text, at most 24 a source), fewer or more. The learner's Mnemonic Reading Writing model writes one request a source; a source too long for its context window is read in consecutive parts, never sampled. Every question stands on a passage its source prints, checked word for word, and one that does not is dropped. The first call prices the writing and starts nothing unless it is free: show the learner the estimate, and once they agree call again with the same arguments and confirm_cost true. Once started it answers with reading_id and work_id while the questions are written in the background, a source at a time: the reading exists once its first source is written, and fills in. list_running_ai_work shows its progress and cancel_ai_work stops it; the sources already written keep their questions. Pass reading_id alone to write a reading's pending sources (a run that failed or was stopped before them). get_mnemonic_reading reads it. Bills the learner's OpenRouter key.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "source_ids": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "The sources to read, in reading order, at most 200, as list_sources or a search returns them.",
                        ],
                        "book": [
                            "type": "string",
                            "description": "A book's book_id or title, as list_sources shows it: all its chapters, in order.",
                        ],
                        "notebook_id": [
                            "type": "string",
                            "description": "The Notebook the reading is made in (list_notebooks); its ticked sources when no sources are named.",
                        ],
                        "density": [
                            "type": "string",
                            "enum": MnemonicReadingDensity.allCases.map(\.rawValue),
                            "description": "How many questions: auto (the default, about one for every 350 words), fewer or more.",
                        ],
                        "reading_id": [
                            "type": "string",
                            "description": "A reading whose pending sources are written; pass it without sources or notebook_id.",
                        ],
                        "confirm_cost": [
                            "type": "boolean",
                            "description": "Pass true only after the learner has seen this tool's estimate and explicitly agreed to the spend. Defaults to false, which prices the writing and starts nothing unless it is free.",
                        ],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "save_mnemonic_reading",
                description: "Save a mnemonic reading whose questions you wrote yourself: the learner reads the sources' own text in ForeverLM with each question right after the passage it tests, as in a reading generate_mnemonic_reading makes. Give sources in reading order, each with its source_id (as list_sources or a search returns it; an id the library does not hold refuses the whole call) and its questions in the order of its text. Each question has quote, the last sentence of the passage it tests copied word for word from the source's text (get_source_content), so ForeverLM can set the question after it; question, on one line, standalone, with one right answer, never yes or no; answer, the short answer first and at most one sentence of why; and why, optional. A question whose quote the source does not print is not saved and is listed under not_grounded. An answered question becomes a card, asked weeks later away from the text, so it never points at its source unnamed (\u{201C}this chapter\u{201D}, \u{201C}the author\u{201D}, \u{201C}this lecture\u{201D}): every question is checked for that before it is saved (a small background model call on the learner's Card Wording Check model), and one that does is reworded once or listed under not_saved; when the check cannot run, the source's questions are not saved and failure says why. Pass title (\u{201C}<book> with questions\u{201D} reads well) and notebook_id to file it in a Notebook, or reading_id to add questions to a reading that exists: a question already there is not saved twice. Returns reading_id and, per source, the saved question ids and what was not saved, with why.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "The reading's title, for a new reading."],
                        "notebook_id": ["type": "string", "description": "The Notebook to file a new reading in, from list_notebooks."],
                        "reading_id": ["type": "string", "description": "A reading to add these questions to, instead of making one."],
                        "sources": [
                            "type": "array",
                            "description": "The sources in reading order, each with its questions in the order of its text.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "source_id": ["type": "string", "description": "The source, from list_sources or a search."],
                                    "questions": [
                                        "type": "array",
                                        "items": [
                                            "type": "object",
                                            "properties": [
                                                "quote": ["type": "string", "description": "The last sentence of the passage the question tests, copied word for word from the source's text."],
                                                "question": ["type": "string", "description": "The question, on one line."],
                                                "answer": ["type": "string", "description": "The short answer first, and at most one sentence of why."],
                                                "why": ["type": "string", "description": "Optional: one line on why the answer is right."],
                                            ],
                                            "required": ["quote", "question", "answer"],
                                        ],
                                    ],
                                ],
                                "required": ["source_id", "questions"],
                            ],
                        ],
                    ],
                    "required": ["sources"],
                ]
            ),
            MCPToolDef(
                name: "get_mnemonic_reading",
                description: "Read a mnemonic reading: its title, its Notebook, its sources in reading order (written, or pending while their questions are not written), and every question with its question_id, source_id, quote (the passage it is asked after), question, answer and why, and where it stands for this learner: unanswered, kept as a Memory card (with its last grade, and due when the card review asks it now, else next_due_at), or retired. counts says how many questions there are, how many are answered and how many are due. While ForeverLM is writing it, writing says how far it has come; last_run says how the last run this session ended. To go through it in a chat, quote the passage and ask one question at a time, show nothing of its answer before the learner answers, and record each answer with answer_mnemonic_question. Reads only. list_docs lists readings as kind mnemonic_reading.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "reading_id": ["type": "string", "description": "The reading, from list_docs (kind mnemonic_reading) or generate_mnemonic_reading."],
                    ],
                    "required": ["reading_id"],
                ]
            ),
            MCPToolDef(
                name: "answer_mnemonic_question",
                description: "Record the learner's answer to one question of a mnemonic reading, as the reading's own Forgot and Remembered do. The question's first answer keeps it as a Memory card at once, remembered or not, with that answer as its first (outcome kept), and the card review asks it again on its schedule. A question kept already is answered as the card review answers a card: recorded only while it is due, once a sitting (already_recorded), not_counted otherwise (an early answer never moves its schedule), retired for a card the learner retired. Pass reading_id and question_id as get_mnemonic_reading returns them, remembered (the learner's own say, or your judgment of what they answered, told to them), and sitting_id when you run several answers as one sitting; without it, a day's answers over MCP are one sitting. A question whose passage its source no longer prints cannot be kept and is refused. Returns the outcome, the card's item_id, its last grade and when it is next asked.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "reading_id": ["type": "string", "description": "The reading, from get_mnemonic_reading."],
                        "question_id": ["type": "string", "description": "The question, from get_mnemonic_reading."],
                        "remembered": ["type": "boolean", "description": "true when the learner remembered the answer, false when they forgot it."],
                        "sitting_id": ["type": "string", "description": "Optional: one id for the answers of one sitting, at most 200 characters."],
                    ],
                    "required": ["reading_id", "question_id", "remembered"],
                ]
            ),
        ]
    }

    static let mnemonicReadingToolNames: Set<String> = [
        "generate_mnemonic_reading", "save_mnemonic_reading", "get_mnemonic_reading", "answer_mnemonic_question",
    ]
}

extension MCPDataStore {
    func executeMnemonicReadingTool(name: String, arguments: [String: Any]) async throws -> String? {
        switch name {
        case "generate_mnemonic_reading": return try await generateMnemonicReading(arguments: arguments)
        case "save_mnemonic_reading": return try await saveMnemonicReading(arguments: arguments)
        case "get_mnemonic_reading": return try await getMnemonicReading(arguments: arguments)
        case "answer_mnemonic_question": return try await answerMnemonicQuestion(arguments: arguments)
        default: return nil
        }
    }

    // MARK: generate_mnemonic_reading

    /// `generate_mnemonic_reading`. `backend` is the writer and `route` the
    /// route the plan is sized and priced against; tests hand in their own,
    /// the app the live ones.
    func generateMnemonicReading(
        arguments: [String: Any],
        backend: (any MnemonicReadingBackend)? = nil,
        route: NotebookWritingRoute? = nil
    ) async throws -> String {
        let named = ((arguments["source_ids"] as? [String]) ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let book = Self.trimmedOrNil(arguments["book"] as? String)
        let notebookArgument = Self.trimmedOrNil(arguments["notebook_id"] as? String)
        let readingID = Self.trimmedOrNil(arguments["reading_id"] as? String)
        let confirmCost = arguments["confirm_cost"] as? Bool ?? false
        let approvedSpendUSD = (arguments["approved_spend_usd"] as? NSNumber)?.doubleValue
            ?? MCPRunningWork.defaultSpendLimitUSD
        var density = MnemonicReadingDensity.auto
        if let raw = Self.trimmedOrNil(arguments["density"] as? String) {
            guard let parsed = MnemonicReadingDensity(rawValue: raw.lowercased()) else {
                throw MCPError.invalidInput("density is auto, fewer or more.")
            }
            density = parsed
        }
        guard [!named.isEmpty, book != nil, readingID != nil].filter({ $0 }).count <= 1 else {
            throw MCPError.invalidInput("Name the sources one way: source_ids, book, or reading_id alone.")
        }
        if readingID != nil, notebookArgument != nil {
            throw MCPError.invalidInput("Pass reading_id alone: the reading keeps its own Notebook and sources.")
        }
        guard !named.isEmpty || book != nil || readingID != nil || notebookArgument != nil else {
            throw MCPError.invalidInput("Pass source_ids (list_sources or a search returns them), a book (its book_id or title from list_sources), a notebook_id for the Notebook's ticked sources, or a reading_id to write its pending sources.")
        }

        // Holds no store gate (`MCPToolRegistry.selfGatedToolNames`): the
        // sources and the reading are read, and the questions saved, through
        // the storage actor.
        let storage = notebookFileStorage
        var notebookID = notebookArgument
        var sourceIDs = named
        if let readingID {
            let (artifact, reading) = try await mnemonicReadingOrRefuse(readingID, writing: true)
            if await MainActor.run(body: { MnemonicReadingCoordinator.shared.run(readingID) != nil }) {
                throw MCPError.invalidInput("\u{2018}\(artifact.title)\u{2019} is being written now; list_running_ai_work shows how far it has come.")
            }
            notebookID = artifact.homeNotebookID
            sourceIDs = reading.pendingSourceIDs
            guard !sourceIDs.isEmpty else {
                return try jsonString([
                    "status": "nothing_to_write",
                    "reading_id": readingID,
                    "message": "Every source of \u{2018}\(artifact.title)\u{2019} has its questions written already. get_mnemonic_reading reads them.",
                ] as [String: Any])
            }
        } else {
            if let book {
                guard let chapters = try await storage.bookChapters(named: book), !chapters.sourceIDs.isEmpty else {
                    throw MCPError.notFound("No book answers to \u{201C}\(book)\u{201D}. Pass a book_id or title as list_sources shows it.")
                }
                sourceIDs = chapters.sourceIDs
            }
            if let notebookID {
                guard let notebook = try await storage.loadLearningGoal(notebookID), notebook.isNotebook else {
                    throw MCPError.notFound("Notebook not found: \(notebookID). Call list_notebooks for the current ids.")
                }
                var team: TeamRecord?
                if let teamID = notebook.teamID {
                    team = try await storage.loadTeam(teamID)
                }
                if let refusal = NotebookImportRefusal.refusal(for: notebook, team: team) {
                    throw MCPError.invalidInput("Nothing was written: a reading can't be filed in \u{2018}\(notebook.title)\u{2019} because \(refusal.reason).")
                }
                if sourceIDs.isEmpty {
                    sourceIDs = try await NotebookSourceLoader.notebookSourceIDs(notebookID: notebookID, storage: storage)
                    guard !sourceIDs.isEmpty else {
                        throw MCPError.invalidInput("Nothing was written: \u{2018}\(notebook.title)\u{2019} has no ticked sources. Tick some with set_notebook_source_selection, or pass source_ids.")
                    }
                }
            }
            // An id the library does not hold refuses the whole call, before
            // anything is read or priced. One it holds but keeps from AI, or
            // archived, is left out with its reason (`left_out`).
            var unknown: [String] = []
            for id in named where try await storage.loadSourceWithoutContent(id) == nil {
                unknown.append(id)
            }
            guard unknown.isEmpty else {
                throw MCPError.invalidInput(
                    "Nothing was written. No library source answers to \(unknown.joined(separator: ", ")). Pass each source_id as list_sources (or search_sources_keyword, search_sources_semantic) returns it."
                )
            }
        }
        guard sourceIDs.count <= MCPToolRegistry.maxMnemonicReadingSources else {
            throw MCPError.invalidInput("Nothing was written. One reading reads at most \(MCPToolRegistry.maxMnemonicReadingSources) sources at a time.")
        }

        let request = MnemonicReadingRequest(notebookID: notebookID, sourceIDs: sourceIDs, density: density, readingID: readingID)
        let plan: MnemonicReadingPlan
        do {
            let materials = try await MnemonicReadingWriter.load(request, storage: storage)
            guard let route = route ?? MnemonicReadingRoute.current() else { throw MnemonicReadingError.noModel }
            plan = MnemonicReadingPlanner.plan(materials, route: route)
        } catch let error as MnemonicReadingError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
        var payload = Self.mnemonicReadingPlanPayload(plan)
        guard plan.questionCount > 0 else {
            payload["status"] = "nothing_to_write"
            payload["message"] = "Nothing was written: none of these sources has text to read with questions (left_out says why)."
            return try jsonString(payload)
        }
        // Price, then confirm: writing that costs anything, or whose price is
        // unknown, waits for the learner to agree to the estimate.
        if !plan.cost.isFree, !confirmCost {
            payload["status"] = "awaiting_confirmation"
            payload["message"] = "Nothing was written. These questions would cost \(plan.cost.label) to write with \(plan.route.modelLabel). Show the learner the estimate, and only after they explicitly agree call generate_mnemonic_reading again with the same arguments and confirm_cost: true."
            return try jsonString(payload)
        }
        if let expected = plan.cost.expectedUSD, expected > approvedSpendUSD {
            payload["status"] = "approval_too_low"
            payload["message"] = String(
                format: "Nothing was started. The estimate is $%.2f, above the $%.2f approved ceiling for this operation. Show the learner the estimate and ask before calling again with a larger approved_spend_usd.",
                expected,
                approvedSpendUSD
            )
            return try jsonString(payload)
        }

        let id = readingID ?? UUID().uuidString.lowercased()
        // The open windows list the reading once it exists and an open one
        // reads each source's questions as they land, as after the Studio's
        // own Make, when this store is the app's library; a store over
        // another database (a test's) has no window.
        let showsInWindow = dbPathOverride == nil
        let workID = MCPRunningWork.shared.startBackground(
            tool: "generate_mnemonic_reading",
            about: plan.title,
            spendLimitUSD: approvedSpendUSD
        ) { @MainActor in
            let callID = MCPRunningWork.currentCallID
            _ = await MnemonicReadingCoordinator.shared.write(plan, readingID: id, storage: storage, backend: backend) { progress in
                if let callID { MCPRunningWork.shared.setDetail(callID, progress.label) }
                if showsInWindow { await Self.reloadStudioArtifacts() }
            }
            if showsInWindow {
                NotificationCenter.default.post(name: .foreverLMDataDidChange, object: nil)
            }
        }
        payload["status"] = "started"
        payload["reading_id"] = id
        payload["work_id"] = workID
        if plan.cost.isFree, !confirmCost { payload["cost_confirmed_by"] = "free_model" }
        let questions = plan.questionCount == 1 ? "1 question" : "about \(plan.questionCount) questions"
        let appears = readingID == nil ? "The reading exists once its first source is written, and fills in" : "The reading fills in as each source is written"
        payload["message"] = "Writing \(questions) in the background (work_id \(workID)), a source at a time. \(appears); get_mnemonic_reading with reading_id \(id) reads it. list_running_ai_work shows the progress, and cancel_ai_work stops it, the sources already written keeping their questions."
        return try jsonString(payload)
    }

    /// The Studio's Docs and outputs read again, as after each source of the
    /// Studio's own Make.
    @MainActor
    private static func reloadStudioArtifacts() async {
        await AppModelBridge.studio?.reloadArtifactsAfterMnemonicReadingWrite()
    }

    /// What the call would write and what it would cost.
    static func mnemonicReadingPlanPayload(_ plan: MnemonicReadingPlan) -> [String: Any] {
        var writing: [String: Any] = [
            "model": plan.route.model,
            "requests": plan.cost.requestCount,
            "estimated_cost": plan.cost.label,
            "basis": "One request a source, or a consecutive part of one too long for the window: its text, and the questions at their usual length. At most is every request's output ceiling, reasoning included.",
        ]
        if let usd = plan.cost.expectedUSD { writing["estimated_cost_usd"] = usd }
        if let usd = plan.cost.maximumUSD { writing["maximum_cost_usd"] = usd }
        var payload: [String: Any] = [
            "title": plan.title,
            "density": plan.density.rawValue,
            "question_count": plan.questionCount,
            "notebook_id": plan.request.notebookID.map { $0 as Any } ?? NSNull(),
            "sources": plan.sources.map { source -> [String: Any] in
                [
                    "source_id": source.source.sourceID,
                    "title": source.source.title,
                    "words": source.source.words,
                    "questions": source.questionCount,
                    "parts": source.parts.count,
                ]
            },
            "source_count": plan.sources.count,
            "summary": plan.summary,
            "estimate": ["writing": writing],
        ]
        if !plan.skipped.isEmpty {
            payload["left_out"] = plan.skipped.map {
                ["source_id": $0.sourceID, "title": $0.isKeptFromAI ? NSNull() : $0.title as Any, "reason": $0.reason] as [String: Any]
            }
        }
        return payload
    }

    // MARK: save_mnemonic_reading

    /// `save_mnemonic_reading`: an assistant's own questions, grounded as
    /// `save_card_drafts` grounds its cards, spending nothing.
    func saveMnemonicReading(arguments: [String: Any]) async throws -> String {
        let entries = arguments["sources"] as? [[String: Any]] ?? []
        guard !entries.isEmpty else {
            throw MCPError.invalidInput("Pass sources: each with its source_id and its questions, in reading order.")
        }
        let readingID = Self.trimmedOrNil(arguments["reading_id"] as? String)
        let notebookID = Self.trimmedOrNil(arguments["notebook_id"] as? String)
        if readingID != nil, notebookID != nil {
            throw MCPError.invalidInput("Pass reading_id without notebook_id: the reading keeps its own Notebook.")
        }
        let storage = notebookFileStorage

        // The sources in reading order, each once: a source named twice keeps
        // its first place, with the later questions after the earlier.
        var order: [String] = []
        var titles: [String: String] = [:]
        var questions: [String: [MnemonicReadingModelQuestion]] = [:]
        var unknown: [String] = []
        for entry in entries {
            guard let sourceID = Self.trimmedOrNil(entry["source_id"] as? String) else {
                throw MCPError.invalidInput("Nothing was saved. Every source needs its source_id.")
            }
            if titles[sourceID] == nil {
                guard let source = try await storage.loadSourceWithoutContent(sourceID) else {
                    if !unknown.contains(sourceID) { unknown.append(sourceID) }
                    continue
                }
                titles[sourceID] = source.title
                order.append(sourceID)
            }
            questions[sourceID, default: []] += (entry["questions"] as? [[String: Any]] ?? []).map { item in
                MnemonicReadingModelQuestion(
                    quote: item["quote"] as? String,
                    question: item["question"] as? String,
                    answer: item["answer"] as? String,
                    why: item["why"] as? String
                )
            }
        }
        guard unknown.isEmpty else {
            throw MCPError.invalidInput("Nothing was saved. No library source answers to \(unknown.joined(separator: ", ")). Pass each source_id as list_sources (or a search) returns it.")
        }
        guard order.count <= MCPToolRegistry.maxMnemonicReadingSources else {
            throw MCPError.invalidInput("Nothing was saved. One call saves at most \(MCPToolRegistry.maxMnemonicReadingSources) sources.")
        }
        let total = questions.values.reduce(0) { $0 + $1.count }
        guard total <= MCPToolRegistry.maxSavedMnemonicQuestions else {
            throw MCPError.invalidInput("Nothing was saved. One call saves at most \(MCPToolRegistry.maxSavedMnemonicQuestions) questions; save the rest with reading_id in another call.")
        }

        let id: String
        let title: String
        var skeleton: MnemonicReadingSkeleton?
        if let readingID {
            let (artifact, _) = try await mnemonicReadingOrRefuse(readingID, writing: true)
            id = readingID
            title = artifact.title
        } else {
            guard let named = Self.trimmedOrNil(arguments["title"] as? String) else {
                throw MCPError.invalidInput("Pass title for a new reading (\u{201C}<book> with questions\u{201D} reads well), or reading_id to add to one.")
            }
            if let notebookID {
                guard let notebook = try await storage.loadLearningGoal(notebookID), notebook.isNotebook else {
                    throw MCPError.notFound("Notebook not found: \(notebookID). Call list_notebooks for the current ids.")
                }
                var team: TeamRecord?
                if let teamID = notebook.teamID {
                    team = try await storage.loadTeam(teamID)
                }
                if let refusal = NotebookImportRefusal.refusal(for: notebook, team: team) {
                    throw MCPError.invalidInput("Nothing was saved: a reading can't be filed in \u{2018}\(notebook.title)\u{2019} because \(refusal.reason).")
                }
            }
            id = UUID().uuidString.lowercased()
            title = MnemonicReading.singleLine(named)
            skeleton = MnemonicReadingSkeleton(
                title: title,
                notebookID: notebookID,
                sections: order.map { ($0, titles[$0] ?? $0) }
            )
        }

        var results: [[String: Any]] = []
        var savedCount = 0
        var exists = readingID != nil
        let wording = CardWordingGate.backend()
        for sourceID in order {
            let written = questions[sourceID] ?? []
            let drafts = MnemonicReadingDrafts.questions(written, sourceID: sourceID, asked: written.count)
            var row: [String: Any] = ["source_id": sourceID, "title": titles[sourceID] ?? sourceID]
            var notSaved = drafts.refused.map { ["question": $0.question, "reason": $0.reason] }
            // Every answered question becomes a card, so each passes the
            // wording gate (`CardWordingGate`) before it is saved.
            let checked: [MnemonicQuestion]
            do {
                let screened = try await CardWordingGate.screen(
                    questions: drafts.questions,
                    sourceTitle: titles[sourceID] ?? sourceID,
                    usage: AIUsageSource(id: sourceID, type: "source", title: titles[sourceID] ?? sourceID),
                    backend: wording
                )
                checked = screened.passed
                notSaved += screened.refused.map { ["question": $0.question, "reason": $0.reason] }
            } catch {
                row["failure"] = "The questions' wording could not be checked, so none was saved. \(error.localizedDescription)"
                if !notSaved.isEmpty { row["not_saved"] = notSaved }
                results.append(row)
                continue
            }
            do {
                let saved = try await storage.saveMnemonicReadingSection(
                    readingID: id,
                    sourceID: sourceID,
                    sourceTitle: titles[sourceID] ?? sourceID,
                    questions: checked,
                    creatingWith: exists ? nil : skeleton
                )
                exists = true
                savedCount += saved.added.count
                row["saved_question_ids"] = saved.added.map(\.id)
                if saved.alreadyWritten > 0 { row["already_written"] = saved.alreadyWritten }
                if !saved.ungrounded.isEmpty {
                    row["not_grounded"] = saved.ungrounded.map { ["question": $0.question, "quote": $0.quote] }
                }
                notSaved += saved.unreadable.map {
                    ["question": $0.question, "reason": "Its answer has a line that reads as a heading or as the question's own metadata."]
                }
            } catch {
                row["failure"] = error.localizedDescription
            }
            if !notSaved.isEmpty { row["not_saved"] = notSaved }
            results.append(row)
        }
        var payload: [String: Any] = [
            "reading_id": id,
            "title": title,
            "sources": results,
            "saved_count": savedCount,
        ]
        if exists {
            payload["message"] = "Saved \(savedCount == 1 ? "1 question" : "\(savedCount) questions") in \u{2018}\(title)\u{2019}. The learner reads it from its Notebook's Studio or from Docs; get_mnemonic_reading reads it."
        } else {
            payload["message"] = "Nothing was saved: no source could take its questions (failure says why for each)."
        }
        return try jsonString(payload)
    }

    // MARK: get_mnemonic_reading

    func getMnemonicReading(arguments: [String: Any]) async throws -> String {
        guard let readingID = Self.trimmedOrNil(arguments["reading_id"] as? String) else {
            throw MCPError.invalidInput("Pass reading_id, from list_docs (kind mnemonic_reading).")
        }
        let (artifact, reading) = try await mnemonicReadingOrRefuse(readingID, writing: false)
        let memory = try await notebookFileStorage.mnemonicReadingMemory(for: reading.questions)
        let now = Date()
        let iso = KnowledgeStore.iso8601Formatter
        let counts = MnemonicReadingProgress.counts(of: reading, memory: memory, now: now)
        var payload: [String: Any] = [
            "reading_id": readingID,
            "title": artifact.title,
            "kind": ArtifactKind.mnemonicReading.rawValue,
            "notebook_id": artifact.homeNotebookID.map { $0 as Any } ?? NSNull(),
            "team_id": artifact.teamID.map { $0 as Any } ?? NSNull(),
            "sources": reading.sections.map { section -> [String: Any] in
                [
                    "source_id": section.sourceID,
                    "title": section.title,
                    "status": section.isWritten ? "written" : "pending",
                    "question_count": section.questions.count,
                ]
            },
            "questions": reading.questions.map { question -> [String: Any] in
                var entry: [String: Any] = [
                    "question_id": question.id,
                    "source_id": question.sourceID,
                    "quote": question.quote,
                    "question": question.question,
                    "answer": question.answer,
                    "memory": Self.mnemonicMemoryPayload(memory[question.id], now: now, iso: iso),
                ]
                if let why = question.why { entry["why"] = why }
                return entry
            },
            "counts": ["questions": counts.questions, "answered": counts.answered, "due": counts.due],
            "guidance": "Quote the passage and ask one question at a time; show nothing of its answer before the learner answers, then record the answer with answer_mnemonic_question.",
        ]
        let (run, outcome) = await MainActor.run {
            (MnemonicReadingCoordinator.shared.run(readingID), MnemonicReadingCoordinator.shared.outcome(forReading: readingID))
        }
        if let run {
            payload["writing"] = ["progress": run.progress.label, "started_at": iso.string(from: run.startedAt)]
        } else if let outcome {
            var last: [String: Any] = ["finished_at": iso.string(from: outcome.finishedAt)]
            if let message = outcome.message { last["message"] = message }
            if let result = outcome.result {
                last["summary"] = result.summary
                let failures = result.failures.map { ["source_id": $0.sourceID, "title": $0.title, "failure": $0.failure ?? ""] }
                if !failures.isEmpty { last["failures"] = failures }
            }
            payload["last_run"] = last
        }
        if run == nil, !reading.pendingSourceIDs.isEmpty {
            payload["pending_note"] = "Pending sources have no questions yet; generate_mnemonic_reading with this reading_id writes them."
        }
        return try jsonString(payload)
    }

    /// A question's standing for the learner, as get_mnemonic_reading and
    /// answer_mnemonic_question say it.
    static func mnemonicMemoryPayload(_ memory: MnemonicQuestionMemory?, now: Date, iso: ISO8601DateFormatter) -> [String: Any] {
        guard let memory else { return ["state": "unanswered"] }
        var payload: [String: Any] = ["item_id": memory.itemID]
        if memory.isRetired {
            payload["state"] = "retired"
        } else {
            payload["state"] = memory.isDue(at: now) ? "due" : "kept"
            payload["next_due_at"] = iso.string(from: memory.dueAt)
        }
        if let remembered = memory.lastRemembered { payload["last_grade"] = remembered ? "remembered" : "forgot" }
        return payload
    }

    // MARK: answer_mnemonic_question

    /// The sitting an `answer_mnemonic_question` without `sitting_id` answers
    /// in: one a local day, so an answer sent again is counted once.
    static func mcpReadingSittingKey(day: String) -> String {
        "mcp-reading-\(day)"
    }

    func answerMnemonicQuestion(arguments: [String: Any]) async throws -> String {
        guard let readingID = Self.trimmedOrNil(arguments["reading_id"] as? String),
              let questionID = Self.trimmedOrNil(arguments["question_id"] as? String) else {
            throw MCPError.invalidInput("Pass reading_id and question_id as get_mnemonic_reading returns them.")
        }
        guard let remembered = try Self.strictBoolArgument(arguments["remembered"], "remembered") else {
            throw MCPError.invalidInput("Nothing was recorded. remembered is required: true when the learner remembered the answer, false when they forgot it.")
        }
        let now = Date()
        let sittingKey = Self.trimmedOrNil(arguments["sitting_id"] as? String)
            ?? Self.mcpReadingSittingKey(day: MemoryReviewGoal.dayKey(for: now))
        guard sittingKey.count <= 200 else {
            throw MCPError.invalidInput("Nothing was recorded. sitting_id is at most 200 characters.")
        }
        let (_, reading) = try await mnemonicReadingOrRefuse(readingID, writing: false)
        guard let question = reading.question(id: questionID) else {
            throw MCPError.notFound("The reading has no question \(questionID). Pass a question_id get_mnemonic_reading returned.")
        }
        let answer: MnemonicReadingAnswer
        do {
            answer = try await notebookFileStorage.recordMnemonicReadingAnswer(question, remembered: remembered, sittingKey: sittingKey, at: now)
        } catch let error as KnowledgeStoreError {
            throw MCPError.invalidInput("Nothing was recorded: \(error.localizedDescription)")
        }
        let iso = KnowledgeStore.iso8601Formatter
        var payload: [String: Any] = [
            "outcome": answer.outcome.rawValue,
            "reading_id": readingID,
            "question_id": questionID,
            "item_id": answer.memory.itemID,
            "remembered": remembered,
            "sitting_id": sittingKey,
            "memory": Self.mnemonicMemoryPayload(answer.memory, now: now, iso: iso),
        ]
        let next = iso.string(from: answer.memory.dueAt)
        switch answer.outcome {
        case .kept:
            payload["message"] = "Kept as a Memory card, \(remembered ? "remembered" : "forgotten") on its first answer. The card review asks it next from \(next)."
        case .recorded:
            payload["message"] = "Recorded as \(remembered ? "remembered" : "forgotten"). The card is next asked from \(next)."
        case .alreadyRecorded:
            payload["message"] = "This sitting already recorded an answer to this question, so it is counted once."
        case .notCounted:
            payload["message"] = "Not recorded: the card is kept already and not due until \(next), and an early answer never moves its schedule."
        case .retired:
            payload["message"] = "Not recorded: the learner retired this card, which is never asked again."
        }
        return try jsonString(payload)
    }

    // MARK: The reading, and the Docs tools

    /// The reading `readingID` names, or a refusal that says how to find one.
    /// `writing`: refused, too, for a team's reading this account can only
    /// read.
    private func mnemonicReadingOrRefuse(_ readingID: String, writing: Bool) async throws -> (artifact: ArtifactRecord, reading: MnemonicReading) {
        let storage = notebookFileStorage
        guard try await storage.loadArtifact(readingID) != nil else {
            throw MCPError.notFound("No mnemonic reading has id \(readingID). list_docs lists readings as kind mnemonic_reading.")
        }
        let found: (artifact: ArtifactRecord, reading: MnemonicReading)
        do {
            found = try await storage.mnemonicReading(readingID)
        } catch let error as KnowledgeStoreError {
            throw MCPError.invalidInput("\(error.localizedDescription) read_doc reads any Doc.")
        } catch let error as ArtifactError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
        if writing, let teamID = found.artifact.teamID {
            let team = try await storage.loadTeam(teamID)
            guard let team, team.canEdit else {
                throw MCPError.invalidInput("Nothing was written: \u{2018}\(found.artifact.title)\u{2019} is a team's reading this account can only read.")
            }
        }
        return found
    }

    /// A reading's body is its questions, which its view, `get_mnemonic_reading`
    /// and an answer read by their markers and ids; the Docs write tools would
    /// break them, and a published page of them would be a list of answers.
    /// Refused even when the record was saved back without its kind, by the
    /// marker its body starts with.
    static func refuseMnemonicReadingChange(_ snapshot: ArtifactMarkdownSnapshot, doing tool: String) throws {
        guard snapshot.artifact.isMnemonicReading(markdown: snapshot.markdown) else { return }
        throw MCPError.invalidInput(
            "\u{2018}\(snapshot.artifact.title)\u{2019} is a mnemonic reading, which \(tool) does not change: its Markdown is its questions, read in ForeverLM beside the sources' own text. save_mnemonic_reading adds questions, generate_mnemonic_reading writes its pending sources, update_doc renames it, and delete_doc deletes it (the cards its answers kept stay in Memory)."
        )
    }
}
#endif
