// Part of ReviewSessionManager: the review plan beside the composer.

import Foundation

extension ReviewSessionManager {
    /// The plan tool is offered in a chat, never in a memory review or a
    /// course quiz, which keep their own plans, in the Feynman Technique,
    /// which follows the learner's order rather than a plan, or in the
    /// ForeverLM Assistant, which keeps no transcript.
    var offersReviewPlanTool: Bool {
        memoryCompanionPlan == nil && courseQuiz == nil
            && sessionPromptKind != .teachBack && sessionPromptKind != .agent
    }

    var reviewPlanToolSpec: AIToolSpec {
        let status: (String, [String]) -> [String: Any] = { description, values in
            ["type": "string", "enum": values, "description": description]
        }
        return AIToolSpec(
            name: ChatReviewPlan.toolName,
            description: "Keep the review plan the learner sees beside the composer. Call it whenever you quiz the learner on a source, an episode or a set of points: once to set the plan when the review starts, and again whenever it changes — after each answer you grade (tick only the points the learner's own answer covered: done when it was right, partial when only part was; a point you explained and the learner has not yet answered stays todo), when you move to another topic, when you ask a new question (open_question), when the learner leaves the plan for a side question or a tangent (push a few words for it onto detours) or comes back (pop it; a return to the plan empties detours), and when something is promised for later (parked). Send the whole plan every time; it replaces the last one. List every point a topic has to cover, so a topic is done only when its points are, and never mark a topic done while points under it are not. Do not write the plan out as a checklist in the reply: the learner sees it beside the composer; say in a sentence where you are instead. When the learner says \"back to the plan\", empty detours and ask the open question again.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "title": [
                        "type": "string",
                        "description": "What the plan covers, a few words: \"Chandel episode #416\".",
                    ],
                    "topics": [
                        "type": "array",
                        "description": "The topics in order, at most \(ChatReviewPlan.maxTopics).",
                        "items": [
                            "type": "object",
                            "properties": [
                                "title": ["type": "string", "description": "The topic in a few words, without a number: the plan numbers its topics itself."],
                                "status": status("active is the one being worked on, at most one.", ["todo", "active", "done", "skipped"]),
                                "points": [
                                    "type": "array",
                                    "description": "Every point the topic has to cover, a few words each.",
                                    "items": [
                                        "type": "object",
                                        "properties": [
                                            "text": ["type": "string"],
                                            "status": status("partial when the learner got only part of it.", ["todo", "partial", "done"]),
                                        ] as [String: Any],
                                        "required": ["text", "status"],
                                    ] as [String: Any],
                                ] as [String: Any],
                            ] as [String: Any],
                            "required": ["title", "status", "points"],
                        ] as [String: Any],
                    ] as [String: Any],
                    "open_question": [
                        "type": "string",
                        "description": "The question waiting for the learner's answer, in one sentence. Omit when none is open.",
                    ],
                    "detours": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Where the chat has wandered from the plan, outermost first, a few words each. Empty when the chat is on the plan.",
                    ] as [String: Any],
                    "parked": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "What was set aside for later and must not be lost.",
                    ] as [String: Any],
                ] as [String: Any],
                "required": ["title", "topics"],
            ]
        )
    }

    /// `update_review_plan` from the tutor: the plan replaced whole, shown at
    /// once beside the composer, and stored with this turn's reply.
    func updateReviewPlan(arguments: [String: Any]) -> AppToolResult {
        guard offersReviewPlanTool else {
            return AppToolResult(text: "Error: this review keeps its own plan.", isError: true)
        }
        let plan: ChatReviewPlan
        do {
            plan = try ChatReviewPlan.fromToolArguments(arguments)
        } catch let error as ChatReviewPlan.ToolError {
            return AppToolResult(text: "Error: \(error.description). Send the whole plan again.", isError: true)
        } catch {
            return AppToolResult(text: "Error: \(error.localizedDescription)", isError: true)
        }
        if let current = reviewPlan, current.title != plan.title,
           earlierReviewPlanTitles.last != current.title {
            earlierReviewPlanTitles.append(current.title)
        }
        reviewPlan = plan
        return AppToolResult(
            text: "Plan saved and shown beside the composer (\(plan.progressLabel)). Do not repeat it as a list in the reply.",
            isError: false
        )
    }

    /// The learner's Clear Plan: the chip goes, the tutor stops reading the
    /// plan, and the chat's latest reply is marked cleared at once so a
    /// reopened chat, and the other devices, hold no plan either. The tutor
    /// can set a new one when asked.
    func clearReviewPlan() async {
        guard let plan = reviewPlan else { return }
        if earlierReviewPlanTitles.last != plan.title {
            earlierReviewPlanTitles.append(plan.title)
        }
        reviewPlan = nil
        guard let sessionID, storedReviewPlan != nil else {
            storedReviewPlan = nil
            return
        }
        do {
            try await storage.appendLineToLatestReviewReply(sessionID: sessionID, line: ChatReviewPlan.clearedLine)
            storedReviewPlan = nil
        } catch {
            // The chip is gone for now; say the clear was not saved, so a
            // reopened chat showing the plan again is not a surprise.
            errorMessage = "The plan was cleared here but not saved: \(error.localizedDescription)"
        }
    }

    /// The plan a reopened chat holds: the last one its replies stored.
    func restoreReviewPlan(from exchanges: [ReviewExchangeRecord]) {
        let replies = exchanges
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
            .flatMap { [$0.question, $0.evaluation ?? ""] }
        let found = ChatReviewPlan.latest(inStoredReplies: replies)
        reviewPlan = found.plan
        storedReviewPlan = found.plan
        earlierReviewPlanTitles = found.earlierTitles
    }

    /// The plan as the tutor reads it each turn, in the volatile tail.
    func reviewPlanTurnContext() -> String {
        guard offersReviewPlanTool, let reviewPlan else { return "" }
        return "\n\n" + reviewPlan.turnContext
    }
}
