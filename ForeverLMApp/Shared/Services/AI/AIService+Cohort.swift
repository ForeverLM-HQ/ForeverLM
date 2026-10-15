import Foundation

extension AIService {

    /// Plan one review session over a cohort.
    ///
    /// Failure is surfaced, never smoothed over: there is no heuristic fallback
    /// plan, because a silently degraded session is worse than an error the
    /// learner can see.
    func planCohortSession(
        cohort: LearningCohort,
        briefs: [CohortSourceBrief],
        recentSessionSummaries: [String],
        budgetMinutes: Int = MemoryReviewBudget.defaultMinutes,
        config: AITaskConfig
    ) async throws -> CohortSessionPlan {
        let system = AITask.cohortSessionPlan.effectivePrompt ?? Prompts.cohortSessionPlanner
        let user = Self.cohortPlannerUserMessage(
            cohort: cohort,
            briefs: briefs,
            recentSessionSummaries: recentSessionSummaries,
            budgetMinutes: budgetMinutes
        )

        let response = try await call(
            config: config,
            system: system,
            user: user,
            maxTokens: 2_500,
            temperature: 0.4
        )
        let plan: CohortSessionPlan = try Self.decodeCohortJSON(response)
        let validated = plan.validated(against: cohort, briefs: briefs)
        // The review is organized by topic: material with ideas and a plan
        // with no topic that survived validation is a failed plan, surfaced
        // rather than run source by source.
        guard !validated.moves.isEmpty,
              !validated.topics.isEmpty || briefs.allSatisfy({ $0.ideas.isEmpty }) else {
            throw AIError.invalidResponse
        }
        return validated
    }

    // MARK: - Message construction

    /// The planner's user message, the tutor's briefing and the conduct text
    /// live in `MemoryReviewTutoring`, which every client compiles. These
    /// forward so the Mac's call sites keep their names.
    static func cohortPlannerUserMessage(
        cohort: LearningCohort,
        briefs: [CohortSourceBrief],
        recentSessionSummaries: [String],
        budgetMinutes: Int = MemoryReviewBudget.defaultMinutes
    ) -> String {
        MemoryReviewTutoring.plannerUserMessage(
            cohort: cohort, briefs: briefs, recentSessionSummaries: recentSessionSummaries,
            budgetMinutes: budgetMinutes
        )
    }

    static func cohortTutorBriefing(
        cohort: LearningCohort,
        briefs: [CohortSourceBrief],
        plan: CohortSessionPlan,
        skippedSources: [String] = [],
        startedAt: Date? = nil,
        budgetMinutes: Int = MemoryReviewBudget.defaultMinutes
    ) -> String {
        MemoryReviewTutoring.briefing(
            cohort: cohort, briefs: briefs, plan: plan, skippedSources: skippedSources,
            startedAt: startedAt, budgetMinutes: budgetMinutes
        )
    }

    static var memoryReviewConductInstructions: String { MemoryReviewTutoring.conductInstructions }

    static func cohortCloserUserMessage(transcript: String, briefs: [CohortSourceBrief]) -> String {
        var lines: [String] = []
        lines.append("SOURCES DISCUSSED")
        lines.append("")
        for brief in briefs {
            lines.append("### [\(brief.source.sourceID)] \(brief.source.title)")
            if let understanding = brief.understanding, !understanding.isEmpty {
                if brief.understandingHasLearnerEdits {
                    lines.append("(The learner has edited this document by hand since you last wrote it.)")
                }
                lines.append("Current understanding document:")
                lines.append(String(understanding.prefix(CohortSourceBrief.maxUnderstandingCharacters)))
            } else {
                lines.append("No understanding document yet — write the first one.")
            }
            // The ideas are here so the closer can say which of them the
            // conversation reached (`discussed_idea_ids`); that set is what the
            // next review is allowed to ask about when the chat is the only
            // reason the source is in it.
            if !brief.ideas.isEmpty {
                lines.append("IDEAS (name the ones this conversation engaged; ids exactly as written):")
                for idea in brief.ideas {
                    lines.append("- [\(idea.id)] \(idea.statement)")
                }
            }
            lines.append("")
        }

        lines.append("TRANSCRIPT")
        lines.append(transcript)
        lines.append("")
        lines.append("""
        Return JSON only:
        {"session_summary": "...", "sources": [{"source_id": "...", \
        "understanding_markdown": "...", "open_thread_count": 0, "discussed_idea_ids": ["..."]}]}
        """)
        return lines.joined(separator: "\n")
    }

    // MARK: - Decoding

    /// Models wrap JSON in prose or fences often enough that locating the object
    /// is worth doing, but a malformed body is an error rather than something to
    /// patch up — a half-understood plan is not better than none.
    static func decodeCohortJSON<T: Decodable>(_ response: String) throws -> T {
        do {
            return try MemoryReviewPlanning.decodeJSON(response)
        } catch {
            throw AIError.invalidResponse
        }
    }
}
