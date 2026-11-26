// MCPToolRegistry: runs the card, practice and review-session tools; one topic's share of `executeTool`.
import Foundation

extension MCPToolRegistry {

    /// Runs one of the card, practice and review-session tools; nil for any other name.
    func executeReviewTool(name: String, arguments: [String: Any], hostSessionID: String?, access: MCPAccessContext) async throws -> String? {
        switch name {
        case "draft_cards":
            return try await store.draftCards(arguments: arguments)
        case "save_card_drafts":
            return try await store.saveCardDrafts(
                cards: arguments["cards"] as? [[String: Any]] ?? [],
                keptByDefault: arguments["kept_by_default"] as? Bool ?? false
            )
        case "list_cards":
            return try await store.listCards(
                status: arguments["status"] as? String,
                notebookID: arguments["notebook_id"] as? String,
                sourceID: arguments["source_id"] as? String,
                limit: try MCPDataStore.intArgument(arguments, "limit")
            )
        case "list_source_card_coverage":
            return try await store.listSourceCardCoverage(
                scope: arguments["scope"] as? String,
                notebookID: arguments["notebook_id"] as? String,
                limit: try MCPDataStore.intArgument(arguments, "limit")
            )
        case "find_card_sources":
            return try await store.findCardSources(
                cardID: arguments["card_id"] as? String,
                question: arguments["question"] as? String,
                answer: arguments["answer"] as? String,
                sourceIDs: arguments["source_ids"] as? [String] ?? [],
                notebookID: arguments["notebook_id"] as? String
            )
        case "triage_cards":
            return try await store.triageCards(
                decisions: arguments["decisions"] as? [[String: Any]] ?? [],
                keepSourceIDs: arguments["keep_source_ids"] as? [String] ?? [],
                skipSourceIDs: arguments["skip_source_ids"] as? [String] ?? []
            )
        case "get_due_cards":
            return try await store.getDueCards(
                notebookID: arguments["notebook_id"] as? String,
                limit: try MCPDataStore.intArgument(arguments, "limit")
            )
        case "record_card_result":
            return try await store.recordCardResult(
                cardID: arguments["card_id"] as? String,
                itemID: arguments["item_id"] as? String,
                remembered: arguments["remembered"],
                asked: arguments["asked"] as? String,
                sittingID: arguments["sitting_id"] as? String,
                practice: arguments["practice"]
            )
        case "practice_cards":
            return try await store.practiceCards(
                cardIDs: arguments["card_ids"],
                title: arguments["title"] as? String
            )
        case "update_card":
            return try await store.updateCard(
                cardID: arguments["card_id"] as? String,
                itemID: arguments["item_id"] as? String,
                front: arguments["front"] as? String,
                back: arguments["back"] as? String,
                why: arguments["why"],
                frontImages: arguments["front_images"],
                backImages: arguments["back_images"],
                startOver: arguments["start_over"],
                alwaysAsk: arguments["always_ask"],
                retire: arguments["retire"]
            )
        case "set_card_details":
            return try await store.setCardDetails(
                cardID: arguments["card_id"] as? String,
                details: arguments["details"]
            )
        case "list_practices":
            return try store.listPractices(status: arguments["status"] as? String)
        case "decide_practice":
            return try await store.decidePractice(
                practiceID: arguments["practice_id"] as? String,
                decision: arguments["decision"] as? String
            )
        case "set_practice":
            return try store.setPractice(
                practiceID: arguments["practice_id"] as? String,
                title: arguments["title"] as? String,
                why: arguments["why"] as? String,
                rule: arguments["rule"],
                status: arguments["status"] as? String,
                scope: arguments["scope"] as? String,
                suggested: arguments["suggested"] as? Bool ?? false
            )
        case "set_review_depth":
            return try store.setReviewDepth(
                sourceID: arguments["source_id"] as? String,
                sourceType: arguments["source_type"] as? String,
                depth: arguments["depth"] as? String ?? ""
            )
        case "record_understanding":
            return try await store.recordUnderstanding(
                sessionID: MCPDataStore.reviewSessionID(from: arguments["session_id"]),
                sessionSummary: arguments["session_summary"] as? String ?? "",
                updates: arguments["updates"] as? [[String: Any]] ?? []
            )
        case "review_suggested_sources":
            return try store.reviewSuggestedSources(
                goalID: arguments["goal_id"] as? String ?? "",
                approve: arguments["approve"] as? [String] ?? [],
                reject: arguments["reject"] as? [String] ?? []
            )
        case "search_sources_semantic":
            return try await store.searchSourcesSemantic(
                queryText: arguments["query"] as? String ?? "",
                limit: arguments["limit"] as? Int ?? 8,
                threshold: Float(arguments["threshold"] as? Double ?? Double(EmbeddingSettings.similarityThreshold)),
                sourceType: arguments["source_type"] as? String,
                addedFrom: Self.searchAddedWindow(arguments).from,
                addedTo: Self.searchAddedWindow(arguments).to,
                notebookID: arguments["notebook_id"] as? String,
                excludeNotebookID: arguments["exclude_notebook_id"] as? String,
                show: arguments["show"] as? String
            )
        case "search_sources_keyword":
            return try store.searchSourcesKeyword(
                keywords: arguments["keywords"] as? [String] ?? [],
                matchAll: (arguments["match"] as? String)?.lowercased() == "all",
                limit: arguments["limit"] as? Int ?? 50,
                snippetsPerSource: arguments["snippets_per_source"] as? Int ?? 2,
                sourceType: arguments["source_type"] as? String,
                notebookID: arguments["notebook_id"] as? String,
                show: arguments["show"] as? String,
                sourceIDs: arguments["source_ids"] as? [String] ?? []
            )
        case "list_shows":
            return try store.listShows(kind: arguments["kind"] as? String)
        case "filter_sources":
            return try store.filterSources(
                show: arguments["show"] as? String,
                author: arguments["author"] as? String,
                titleContains: arguments["title_contains"] as? String,
                text: arguments["text"] as? String,
                sourceType: arguments["source_type"] as? String,
                includeArchived: arguments["include_archived"] as? Bool ?? false,
                limit: arguments["limit"] as? Int ?? 200
            )
        case "browse_library":
            return try await store.browseLibrary(
                text: arguments["text"] as? String,
                sourceType: arguments["source_type"] as? String,
                notebookID: arguments["notebook_id"] as? String,
                limit: arguments["limit"] as? Int ?? 40
            )
        case "start_review_session":
            return try await store.startScopedReviewSession(
                topic: arguments["topic"] as? String ?? "",
                sourceID: arguments["source_id"] as? String,
                sourceIDs: arguments["source_ids"] as? [String] ?? [],
                notebookID: arguments["notebook_id"] as? String,
                operationID: arguments["operation_id"] as? String,
                hostSessionID: hostSessionID
            )
        case "end_review_session":
            guard let overallScore = ToolArgumentNumber.value(arguments["overall_score"]),
                  overallScore.isFinite,
                  (0.0...1.0).contains(overallScore) else {
                throw MCPError.invalidInput(
                    "overall_score must be a finite number from 0.0 to 1.0."
                )
            }
            return try store.endReviewSession(
                sessionID: MCPDataStore.reviewSessionID(from: arguments["session_id"]),
                hostSessionID: hostSessionID,
                overallScore: overallScore,
                summary: arguments["summary"] as? String ?? "",
                transcript: arguments["transcript"] as? String ?? arguments["chat_export"] as? String,
                gaps: arguments["gaps"] as? [[String: Any]] ?? [],
                memoryAttempts: arguments["memory_attempts"] as? [[String: Any]] ?? [],
                sourceIDs: arguments["source_ids"] as? [String] ?? [],
                topic: arguments["topic"] as? String
            )
        case "get_review_sessions": return try store.getReviewSessions(topic: arguments["topic"] as? String, sourceId: arguments["source_id"] as? String)
        case "get_review_session_transcript":
            return try store.getReviewSessionTranscript(sessionID: MCPDataStore.reviewSessionID(from: arguments["session_id"]))
        case "import_review_chat":
            return try store.importReviewChat(
                title: arguments["title"] as? String ?? "",
                transcript: arguments["transcript"] as? String ?? arguments["chat_export"] as? String ?? "",
                transcriptFile: arguments["transcript_file"] as? String,
                sourceIDs: arguments["source_ids"] as? [String],
                summary: arguments["summary"] as? String,
                overallScore: clampUnitInterval(optional: arguments["overall_score"] as? Double),
                modelProvider: arguments["model_provider"] as? String,
                modelID: arguments["model_id"] as? String,
                notebookID: arguments["notebook_id"] as? String,
                sessionID: (arguments["session_id"] as? String).map { MCPDataStore.reviewSessionID(from: $0) },
                startedAt: (arguments["started_at"] as? String).flatMap(MCPDataStore.parseISODate),
                endedAt: (arguments["ended_at"] as? String).flatMap(MCPDataStore.parseISODate),
                marksReviewed: arguments["mark_reviewed"] as? Bool
            )
        case "search_review_sessions":
            return try store.searchReviewSessions(
                queryText: arguments["query"] as? String ?? "",
                limit: arguments["limit"] as? Int ?? 10
            )
        case "list_review_session_links": return try store.listReviewSessionLinks()
        default:
            return nil
        }
    }
}
