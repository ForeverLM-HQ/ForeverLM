#if os(macOS)
import Foundation

// MARK: - draft_cards
//
// Make Cards for an assistant (docs/memory-design.md, "Drafting"): the
// Reader's and the Studio's Make Cards in one call, with the protocol every
// paid generator here has. The first call reads the sources, plans the
// drafting and prices it, and starts nothing unless it is free; agreed
// (confirm_cost, within approved_spend_usd), it runs as background work with
// a work_id — the same run the app's own Make Cards starts, so the Reader and
// the notebook's Studio show it with its Stop — and the cards arrive kept by
// default in Memory's To Check. An unknown source id refuses the whole call
// and names list_sources. The web's Make cards calls this through the
// gateway.

extension MCPToolRegistry {
    /// The most sources one `draft_cards` call reads.
    static let maxCardDraftingSources = 100

    static var draftCardsToolDef: MCPToolDef {
        MCPToolDef(
            name: "draft_cards",
            description: "Draft Memory cards from sources in ForeverLM, as Make Cards in the Reader or a Notebook's Studio does, for the learner to go through in Memory's To Check: the cards arrive kept by default (ticked, so one Keep Cards keeps them while the learner unticks any to leave out), and only a kept card is ever reviewed. Name the sources with source_ids, as list_sources or a search returns them (an id the library does not hold refuses the whole call), or pass notebook_id alone for the Notebook's own ticked sources (list_notebook_sources in_chat, without via_context_notebook_id); with both, notebook_id is the Notebook the cards are made in, whose decided cards guide the drafting and whose To Check lists them. count is auto (the default: about 4 a source, at most 40) or how many cards in all, from 1 to 40, shared across the sources; focus says what the cards should serve. Each source's whole text is read; one too long for the drafting model's context window is read as evenly spaced excerpts and named under sampled. Questions a walkthrough of the source already asks become cards with no model call; the learner's Card Drafting model drafts the rest, starting from the source's review-guide questions, the learner's highlights and notes, and its ideas, and never drafts again a seed or a question the source's cards already hold, kept or skipped. Every card stands on a passage its source prints, checked word for word: a card whose passage is not found is reported, never offered. The first call prices the drafting and starts nothing unless it is free: show the learner the estimate, and once they agree call again with the same arguments and confirm_cost true. Once started it answers with work_id while the cards are drafted in the background; list_running_ai_work shows its progress, cancel_ai_work stops it (the sources already drafted keep their cards), and list_cards lists the cards to check, with what each run drafted under drafting. Bills the learner's OpenRouter key.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "source_ids": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "The sources to draft cards from, at most 100, as list_sources or a search returns them. Omit with notebook_id for the Notebook's ticked sources.",
                    ],
                    "notebook_id": [
                        "type": "string",
                        "description": "The Notebook the cards are made in (list_notebooks): its ticked sources when source_ids is omitted, and its decided cards guide the drafting.",
                    ],
                    "count": [
                        "type": "string",
                        "description": "auto (the default: about 4 cards a source, at most 40), or how many cards in all, from 1 to 40, such as \"10\".",
                    ],
                    "focus": [
                        "type": "string",
                        "description": "Optional: what the cards should serve, in the learner's words.",
                    ],
                    "confirm_cost": [
                        "type": "boolean",
                        "description": "Pass true only after the learner has seen this tool's estimate and explicitly agreed to the spend. Defaults to false, which prices the drafting and starts nothing unless it is free.",
                    ],
                ],
                "required": [] as [String],
            ]
        )
    }
}

extension MCPDataStore {
    /// `draft_cards`. `backend` is the drafter and `route` the model route
    /// the plan is sized and priced against; tests hand in their own, the
    /// app the live ones.
    func draftCards(
        arguments: [String: Any],
        backend: (any CardDraftingBackend)? = nil,
        route: CardDraftingRoute? = nil
    ) async throws -> String {
        let named = ((arguments["source_ids"] as? [String]) ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let notebookID = Self.trimmedOrNil(arguments["notebook_id"] as? String)
        guard !named.isEmpty || notebookID != nil else {
            throw MCPError.invalidInput("Pass source_ids (list_sources or a search returns them), or a notebook_id for the Notebook's ticked sources.")
        }
        guard let count = MemoryCardRequestCount(argument: arguments["count"]) else {
            throw MCPError.invalidInput("count is auto, or how many cards in all from 1 to \(MemoryCardRequestCount.maximumPerRequest).")
        }
        let focus = Self.trimmedOrNil(arguments["focus"] as? String)
        let confirmCost = arguments["confirm_cost"] as? Bool ?? false
        let approvedSpendUSD = (arguments["approved_spend_usd"] as? NSNumber)?.doubleValue
            ?? MCPRunningWork.defaultSpendLimitUSD

        // Holds no store gate (`MCPToolRegistry.selfGatedToolNames`): the
        // sources and decks are read, and the drafts saved, through the
        // storage actor.
        let storage = notebookFileStorage
        var notebookTitle: String?
        if let notebookID {
            guard let notebook = try await storage.loadLearningGoal(notebookID), notebook.isNotebook else {
                throw MCPError.notFound("Notebook not found: \(notebookID). Call list_notebooks for the current ids.")
            }
            notebookTitle = notebook.title
        }
        var sourceIDs = named
        if sourceIDs.isEmpty, let notebookID {
            sourceIDs = try await NotebookSourceLoader.notebookSourceIDs(notebookID: notebookID, storage: storage)
            guard !sourceIDs.isEmpty else {
                throw MCPError.invalidInput("Nothing was drafted: \u{2018}\(notebookTitle ?? notebookID)\u{2019} has no ticked sources. Tick some with set_notebook_source_selection, or pass source_ids.")
            }
        }
        guard sourceIDs.count <= MCPToolRegistry.maxCardDraftingSources else {
            throw MCPError.invalidInput("Nothing was drafted. One call reads at most \(MCPToolRegistry.maxCardDraftingSources) sources; draft the rest in another call.")
        }

        // Every source first: an id the library does not hold refuses the
        // whole call, before anything is read or priced. One it holds but
        // keeps from AI, or archived, is left out with its reason
        // (`left_out`), as the app's own Make Cards leaves it out.
        var unknown: [String] = []
        for id in sourceIDs where try await storage.loadSourceWithoutContent(id) == nil {
            unknown.append(id)
        }
        guard unknown.isEmpty else {
            throw MCPError.invalidInput(
                "Nothing was drafted. No library source answers to \(unknown.joined(separator: ", ")). Pass each source_id as list_sources (or search_sources_keyword, search_sources_semantic) returns it."
            )
        }

        let request = CardDraftingRequest(
            notebookID: notebookID,
            sourceIDs: sourceIDs,
            count: count,
            focus: focus,
            trigger: .requested
        )
        let materials = try await CardDraftingService.load(request, storage: storage, stateDefaults: cardStateDefaults)
        guard let route = route ?? CardDraftingRoute.current() else {
            throw MCPError.invalidInput(CardDraftingError.noModel.localizedDescription)
        }
        let plan = CardDraftingService.plan(materials, route: route)
        var payload = Self.cardDraftingPlanPayload(plan)
        if let notebookTitle { payload["notebook"] = notebookTitle }

        guard plan.cardCount > 0 else {
            payload["status"] = "nothing_to_draft"
            payload["message"] = "Nothing was drafted: none of these sources can take cards now (left_out says why)."
            return try jsonString(payload)
        }
        // Price, then confirm: drafting that costs anything, or whose price
        // is unknown, waits for the learner to agree to the estimate.
        if !plan.cost.isFree, !confirmCost {
            payload["status"] = "awaiting_confirmation"
            payload["message"] = "Nothing was drafted. These cards would cost \(plan.cost.label) to draft with \(plan.route.writing.modelLabel). Show the learner the estimate, and only after they explicitly agree call draft_cards again with the same arguments and confirm_cost: true."
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

        let sourceCount = plan.sources.count
        let workID = MCPRunningWork.shared.startBackground(
            tool: "draft_cards",
            about: sourceCount == 1 ? "cards from \(plan.sources[0].source.title)" : "cards from \(sourceCount) sources",
            spendLimitUSD: approvedSpendUSD
        ) { @MainActor in
            let callID = MCPRunningWork.currentCallID
            let result = await CardDraftingCoordinator.shared.write(plan, storage: storage, backend: backend) { progress in
                if let callID { MCPRunningWork.shared.setDetail(callID, progress.label) }
            }
            // The open windows count the cards to check again.
            if case .success = result {
                NotificationCenter.default.post(name: .foreverLMDataDidChange, object: nil)
            }
        }
        payload["status"] = "started"
        payload["work_id"] = workID
        if plan.cost.isFree, !confirmCost {
            payload["cost_confirmed_by"] = plan.callCount == 0 ? "no_model_call" : "free_model"
        }
        payload["message"] = "Drafting \(plan.cardCount == 1 ? "1 card" : "\(plan.cardCount) cards") in the background (work_id \(workID)). list_running_ai_work shows its progress, and cancel_ai_work stops it; the sources already drafted keep their cards. When it is no longer listed, list_cards lists the cards to check, which the learner keeps with one press, and its drafting field says what this run drafted and what was not found in its source."
        return try jsonString(payload)
    }

    /// What the call would draft and what it would cost.
    static func cardDraftingPlanPayload(_ plan: CardDraftingPlan) -> [String: Any] {
        var drafting: [String: Any] = [
            "model": plan.route.writing.model,
            "requests": plan.cost.requestCount,
            "estimated_cost": plan.callCount == 0 ? "free" : plan.cost.label,
            "basis": "One request a source the model drafts for, its whole text or its excerpts and the cards at their usual length; at most is every request's output ceiling, reasoning included. A walkthrough's own questions cost nothing.",
        ]
        if let usd = plan.cost.expectedUSD { drafting["estimated_cost_usd"] = usd }
        if let usd = plan.cost.maximumUSD { drafting["maximum_cost_usd"] = usd }
        var payload: [String: Any] = [
            "count": plan.request.count.argument,
            "card_count": plan.cardCount,
            "notebook_id": plan.request.notebookID.map { $0 as Any } ?? NSNull(),
            "focus": plan.request.focus.map { $0 as Any } ?? NSNull(),
            "sources": plan.sources.map { source -> [String: Any] in
                var entry: [String: Any] = [
                    "source_id": source.source.sourceID,
                    "title": source.source.title,
                    "cards": source.quota,
                    "free_cards": source.free.count,
                    "seeds": source.source.seeds.count,
                    "sampled": source.isSampled,
                ]
                if source.source.requestedID != source.source.sourceID {
                    entry["team_copy_id"] = source.source.requestedID
                }
                return entry
            },
            "source_count": plan.sources.count,
            "summary": plan.summary,
            "estimate": ["drafting": drafting],
        ]
        if !plan.skipped.isEmpty {
            payload["left_out"] = plan.skipped.map {
                ["source_id": $0.sourceID, "title": $0.isKeptFromAI ? NSNull() : $0.title as Any, "reason": $0.reason] as [String: Any]
            }
        }
        if !plan.sampledTitles.isEmpty {
            payload["sampled"] = plan.sampledTitles
            payload["sampling_note"] = "\(CardDraftingSampling.marker): these sources are too long for the drafting model's context window in one request, so their cards are drafted from evenly spaced excerpts of the whole text."
        }
        return payload
    }

    /// What `draft_cards` runs drafted, for `list_cards`: the runs that
    /// touched these sources (every run kept this session when nil), newest
    /// first.
    func cardDraftingRunsPayload(touching sourceIDs: Set<String>?) async -> [[String: Any]] {
        await MainActor.run {
            let coordinator = CardDraftingCoordinator.shared
            let formatter = ISO8601DateFormatter()
            var entries: [[String: Any]] = coordinator.runs
                .filter { run in sourceIDs.map { !$0.isDisjoint(with: run.sourceIDs) } ?? true }
                .map { run in
                    [
                        "state": "drafting",
                        "started_at": formatter.string(from: run.startedAt),
                        "progress": run.progress.label,
                        "source_ids": run.sourceIDs,
                    ]
                }
            for outcome in coordinator.outcomes(touching: sourceIDs) {
                var entry: [String: Any] = [
                    "state": outcome.result == nil ? "stopped_or_failed" : "done",
                    "finished_at": formatter.string(from: outcome.finishedAt),
                ]
                if let message = outcome.message { entry["message"] = message }
                if let result = outcome.result {
                    entry["summary"] = result.summary
                    entry["sources"] = result.sources.map { source -> [String: Any] in
                        var row: [String: Any] = [
                            "source_id": source.sourceID,
                            "title": source.title,
                            "added_card_ids": source.added.map(\.id),
                            "already_drafted": source.alreadyDrafted,
                            "sampled": source.isSampled,
                        ]
                        if !source.ungrounded.isEmpty {
                            row["not_grounded"] = source.ungrounded.map(\.front)
                        }
                        if !source.notSaved.isEmpty {
                            row["not_saved"] = source.notSaved.map { ["front": $0.front, "reason": $0.reason] }
                        }
                        if let failure = source.failure { row["failure"] = failure }
                        return row
                    }
                    if !result.skipped.isEmpty {
                        entry["left_out"] = result.skipped.map { ["source_id": $0.sourceID, "title": $0.isKeptFromAI ? NSNull() : $0.title as Any, "reason": $0.reason] as [String: Any] }
                    }
                }
                entries.append(entry)
            }
            return entries
        }
    }
}
#endif
