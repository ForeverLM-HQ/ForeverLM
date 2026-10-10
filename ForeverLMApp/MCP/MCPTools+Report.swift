#if os(macOS)
import Foundation

// MARK: - generate_report
//
// A Notebook's report, for an assistant: the Studio's Report tile — its
// options and Make — in one call (docs/notebooks-design.md, "Reports"). The
// call plans and prices first and spends nothing until the learner agreed to
// the estimate (confirm_cost) or the model is free; then the writing runs as
// background work with a work_id — the same run the app's own Make starts, so
// it shows as a pending row in the Notebook and its Stop ends it — and the
// report is saved as a Doc in the Notebook under the doc_id the answer names.

extension MCPToolRegistry {
    static var reportToolDef: MCPToolDef {
        MCPToolDef(
            name: "generate_report",
            description: "Write a Notebook's report in ForeverLM, as its Studio's Report does, and save it as a Doc in the Notebook. Formats: briefing (an executive summary, the key themes with their evidence, the important quotations, where the sources agree and conflict, and the open questions), study_guide (an overview, a ten-question short-answer quiz with its answer key, five essay questions and a glossary of key terms), meeting_questions (questions to bring to a meeting about the sources, grouped by theme, each with why it matters, and the three to ask first), document_feedback (constructive, specific feedback on one document, subject_id, judged against the Notebook's other sources) and custom (the report the learner's instruction describes). focus leads any format but custom. It is written by the learner's Report Writing model over the Notebook's own ticked sources (list_notebook_sources in_chat, without a context notebook's rows, via_context_notebook_id; set_notebook_source_selection) unless source_ids names some of its own sources; sources with no text yet are left out and listed. Every source is read whole when the model's context window takes them together; otherwise the longest are read from the ideas stored for them, or from a condensed account of their whole text written for this report, and the answer says which — nothing is cut. Each passage stands on the sources it cites, as the Doc's own citations, and the Doc closes with a card for each source and the recipe it was made from (read_doc returns it as report). The first call prices the writing and starts nothing unless the model is free: show the learner the estimate, and once they agree call again with the same arguments and confirm_cost true. Once started it answers with work_id and doc_id while the report is written in the background; list_running_ai_work shows its stage, cancel_ai_work stops it and nothing is saved, and read_doc with the doc_id returns the report once saved, or says why it was not. Bills the learner's OpenRouter key.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "notebook_id": [
                        "type": "string",
                        "description": "The Notebook the report is written from and filed in (list_notebooks).",
                    ],
                    "format": [
                        "type": "string",
                        "enum": ReportFormat.allCases.map(\.rawValue),
                        "description": "briefing (the default), study_guide, meeting_questions, document_feedback or custom.",
                    ],
                    "focus": [
                        "type": "string",
                        "description": "Optional: what the report should focus on, in the learner's words. It leads the report. Not used with custom, whose instruction says it all.",
                    ],
                    "instruction": [
                        "type": "string",
                        "description": "Required for custom, and used only there: what the report should be, in the learner's words: its purpose, sections, tone or length.",
                    ],
                    "subject_id": [
                        "type": "string",
                        "description": "Required for document_feedback, and used only there: the document the feedback is about, one of the Notebook's sources (list_notebook_sources) or one of its Docs (list_docs with notebook_id). A source of the Notebook that is not ticked is read as well.",
                    ],
                    "take": [
                        "type": "string",
                        "description": "Optional (Think first): what the learner thinks matters most, in their own words, written before seeing the report. The report opens with it under \"Your take\", as written, and ends with \"Where this differs from your take\": what their take saw that the report does not, and the other way round, never a grade. Pass only the learner's words, never your own.",
                    ],
                    "source_ids": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Write from these of the Notebook's own sources, in this order. Omit for its own ticked sources (in_chat, not via_context_notebook_id).",
                    ],
                    "confirm_cost": [
                        "type": "boolean",
                        "description": "Pass true only after the learner has seen this tool's estimate and explicitly agreed to the spend. Defaults to false, which prices the writing and starts nothing unless the model is free.",
                    ],
                ],
                "required": ["notebook_id"],
            ]
        )
    }
}

extension MCPDataStore {
    /// `generate_report`. `backend` is the writer and `route` the model route
    /// it is sized and priced against; tests hand in their own, the app the
    /// live ones.
    func generateReport(
        arguments: [String: Any],
        backend: (any ReportModelBackend)? = nil,
        route: NotebookWritingRoute? = nil
    ) async throws -> String {
        let notebookID = (arguments["notebook_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !notebookID.isEmpty else {
            throw MCPError.invalidInput("notebook_id is required: the Notebook the report is written from and filed in. list_notebooks shows each id.")
        }
        var options = try Self.reportOptions(arguments)
        let subjectID = options.format.needsSubject
            ? (arguments["subject_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            : nil
        if options.format.needsInstruction, options.trimmedInstruction == nil {
            throw MCPError.invalidInput("instruction is required for format custom: what the report should be, in the learner's words.")
        }
        if options.format.needsSubject, subjectID == nil {
            throw MCPError.invalidInput("subject_id is required for format document_feedback: the source (list_notebook_sources) or Doc (list_docs with notebook_id) the feedback is about.")
        }
        let namedSourceIDs = (arguments["source_ids"] as? [String])?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let confirmCost = arguments["confirm_cost"] as? Bool ?? false
        let approvedSpendUSD = (arguments["approved_spend_usd"] as? NSNumber)?.doubleValue
            ?? MCPRunningWork.defaultSpendLimitUSD

        // Holds no store gate (`MCPToolRegistry.selfGatedToolNames`): the
        // Notebook, its team and its sources are read through the storage
        // actor, and the report is saved there too.
        let storage = notebookFileStorage
        guard let notebook = try await storage.loadLearningGoal(notebookID), notebook.isNotebook else {
            throw MCPError.notFound("Notebook not found: \(notebookID). Call list_notebooks for the current ids.")
        }
        var team: TeamRecord?
        if let teamID = notebook.teamID {
            team = try await storage.loadTeam(teamID)
        }
        if let refusal = NotebookImportRefusal.refusal(for: notebook, team: team) {
            throw MCPError.invalidInput("Nothing was written: a report can't be filed in \u{2018}\(notebook.title)\u{2019} because \(refusal.reason).")
        }

        // The sources read: those named, or the ticked ones; a document the
        // feedback is about that is one of the Notebook's sources is read as
        // well when it is not among them.
        var sourceIDs = namedSourceIDs?.isEmpty == false ? namedSourceIDs : nil
        if let subjectID {
            let pool = try await NotebookSourceLoader.ownSourceIDs(notebookID: notebookID, storage: storage)
            if pool.contains(subjectID) {
                var selected = sourceIDs ?? []
                if sourceIDs == nil {
                    selected = try await NotebookSourceLoader.notebookSourceIDs(notebookID: notebookID, storage: storage)
                }
                if !selected.contains(subjectID) { sourceIDs = selected + [subjectID] }
            }
        }

        let writer = backend ?? LiveReportModelBackend(aiService: AIService())
        let service = ReportGeneratorService(storage: storage, backend: writer)
        let plan: ReportPlan
        do {
            let notebook = try await service.load(notebookID: notebookID, sourceIDs: sourceIDs)
            var document: ReportSubjectDocument?
            if let subjectID {
                guard let subject = notebook.subject(id: subjectID) else {
                    throw ReportGenerationError.subjectNotInNotebook(subjectID)
                }
                options.subject = subject
                if subject.kind == .doc {
                    document = try await service.loadSubjectDocument(subject.id, in: notebook)
                }
            }
            guard let route = route ?? LiveReportModelBackend.currentRoute() else {
                throw ReportGenerationError.noModelConfigured
            }
            plan = try ReportGeneratorService.plan(
                notebook,
                request: ReportRequest(notebookID: notebookID, options: options, sourceIDs: sourceIDs),
                subjectDocument: document,
                route: route
            )
        } catch let error as ReportGenerationError {
            throw MCPError.invalidInput(error.localizedDescription)
        }

        var payload = Self.reportPlanPayload(plan)
        payload["notebook"] = notebook.title
        // Price, then confirm: a writing that costs anything, or whose price
        // is unknown, waits for the learner to agree to the estimate.
        if !plan.writingCost.isFree, !confirmCost {
            payload["status"] = "awaiting_confirmation"
            payload["message"] = "Nothing was written. This report would cost \(plan.writingCost.label) to write with \(plan.route.modelLabel). Show the learner the estimate, and only after they explicitly agree call generate_report again with the same arguments and confirm_cost: true."
            return try jsonString(payload)
        }
        if let expected = plan.writingCost.expectedUSD, expected > approvedSpendUSD {
            payload["status"] = "approval_too_low"
            payload["message"] = String(
                format: "Nothing was started. The estimate is $%.2f, above the $%.2f approved ceiling for this operation. Show the learner the estimate and ask before calling again with a larger approved_spend_usd.",
                expected,
                approvedSpendUSD
            )
            return try jsonString(payload)
        }

        let artifactID = UUID().uuidString.lowercased()
        let title = notebook.title
        // The open window lists the saved report when this store is the
        // app's library; a store over another database (a test's) has no window.
        let showsInWindow = dbPathOverride == nil
        let workID = MCPRunningWork.shared.startBackground(
            tool: "generate_report",
            about: "report for \(title)",
            spendLimitUSD: approvedSpendUSD
        ) { @MainActor in
            let callID = MCPRunningWork.currentCallID
            let coordinator = ReportGenerationCoordinator.shared
            let result = await coordinator.write(plan, artifactID: artifactID, storage: storage, backend: writer) { stage in
                if let callID { MCPRunningWork.shared.setDetail(callID, stage.label) }
            }
            // A run that ended without a report leaves its note with the
            // coordinator, which read_doc on the doc_id reads.
            guard case .success(let report) = result else { return }
            if showsInWindow, let studio = try? AppModelBridge.requireStudio() {
                await coordinator.show(report, in: studio)
            }
            NotificationCenter.default.post(name: .foreverLMDataDidChange, object: nil)
        }
        payload["status"] = "started"
        payload["work_id"] = workID
        payload["doc_id"] = artifactID
        if plan.writingCost.isFree, !confirmCost {
            payload["cost_confirmed_by"] = "free_model"
        }
        payload["message"] = "Writing the report for \u{2018}\(title)\u{2019} in the background (work_id \(workID)); it takes a minute or more. list_running_ai_work shows its stage, and cancel_ai_work stops it with nothing saved. When it is no longer listed, read_doc with doc_id \(artifactID) returns the report, or says why it was not saved."
        return try jsonString(payload)
    }

    /// `read_doc` on a report that never came: why, while the coordinator
    /// remembers it — still being written, stopped, or failed. Nil for any
    /// other id.
    func reportNotSavedMessage(_ artifactID: String) async -> String? {
        await MainActor.run {
            let coordinator = ReportGenerationCoordinator.shared
            if let run = coordinator.run(artifactID) {
                return "The report \(artifactID) is still being written (\(run.stage.label)); list_running_ai_work shows it. Call read_doc again once it is no longer listed."
            }
            guard let note = coordinator.note(forReport: artifactID) else { return nil }
            return "The report \(artifactID) was not saved. \(note.message)"
        }
    }

    /// The format, focus and instruction, from the tool's words.
    static func reportOptions(_ arguments: [String: Any]) throws -> ReportOptions {
        var options = ReportOptions()
        if let raw = (arguments["format"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !raw.isEmpty {
            guard let format = ReportFormat(rawValue: raw) else {
                throw MCPError.invalidInput("format must be one of \(ReportFormat.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            options.format = format
        }
        options.focus = (arguments["focus"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        options.instruction = (arguments["instruction"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        options.take = (arguments["take"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return options
    }

    /// What the call would write and what it would cost.
    static func reportPlanPayload(_ plan: ReportPlan) -> [String: Any] {
        let options = plan.options
        var writing: [String: Any] = [
            "model": plan.route.model,
            "requests": plan.writingCost.requestCount,
            "estimated_cost": plan.writingCost.label,
            "basis": "The report at its target length and every condensing call; at most is every request's output ceiling, reasoning included.",
        ]
        if let usd = plan.writingCost.expectedUSD { writing["estimated_cost_usd"] = usd }
        if let usd = plan.writingCost.maximumUSD { writing["maximum_cost_usd"] = usd }
        var payload: [String: Any] = [
            "notebook_id": plan.request.notebookID,
            "format": options.format.rawValue,
            "focus": options.trimmedFocus.map { $0 as Any } ?? NSNull(),
            "instruction": options.trimmedInstruction.map { $0 as Any } ?? NSNull(),
            "take": options.trimmedTake.map { $0 as Any } ?? NSNull(),
            "target_words": "\(options.format.wordRange.lowerBound)-\(options.format.wordRange.upperBound)",
            "sources": plan.sources.map { source -> [String: Any] in
                var entry: [String: Any] = [
                    "marker": "S\(source.number)",
                    "source_id": source.candidate.source.id,
                    "title": source.candidate.source.title,
                    "read_as": source.readAs.rawValue,
                ]
                if !source.parts.isEmpty { entry["condensing_calls"] = source.parts.count }
                if source.isSubject { entry["is_subject"] = true }
                return entry
            },
            "source_count": plan.sources.count,
            "summary": plan.sourcesSummary,
            "recipe": plan.recipe.line,
            "estimate": ["writing": writing],
        ]
        if let subject = options.effectiveSubject {
            payload["subject"] = [
                "id": subject.id,
                "kind": subject.kind.rawValue,
                "title": plan.subjectDocument?.title ?? subject.title,
            ] as [String: Any]
        }
        if !plan.skipped.isEmpty {
            payload["left_out"] = plan.skipped.map {
                ["source_id": $0.sourceID, "title": $0.title, "reason": $0.reason] as [String: Any]
            }
        }
        if plan.sources.contains(where: { $0.readAs != .whole }) {
            payload["reading_note"] = "The writing model's context window cannot take every source whole: read_as ideas means only the ideas stored for that source are given, condensed means a condensed account of its whole text, written for this report. Nothing is cut."
        }
        return payload
    }

    /// A report's recipe, as read_doc returns it.
    static func reportRecipePayload(_ recipe: ReportRecipe) -> [String: Any] {
        [
            "format": recipe.format.rawValue,
            "source_count": recipe.sourceCount,
            "subject_title": recipe.subjectTitle.map { $0 as Any } ?? NSNull(),
            "subject_is_doc": recipe.subjectIsDocument,
            "focus": (recipe.format.needsInstruction ? nil : recipe.note).map { $0 as Any } ?? NSNull(),
            "instruction": (recipe.format.needsInstruction ? recipe.note : nil).map { $0 as Any } ?? NSNull(),
            "summary": recipe.line,
        ]
    }
}

private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}
#endif
