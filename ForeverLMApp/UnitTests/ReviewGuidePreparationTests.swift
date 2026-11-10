import Foundation
import Testing
@testable import ForeverLM

/// The review guide's preparation task, the chat's own purposes that run on
/// Background's model, the chat effort, and the text review's closure rule.
/// These lived with the Mac's realtime voice tests until realtime voice went
/// on 2026-10-01; the task (`realtime_review_preparation`, a synced id) still
/// writes the review guides today's memory review reads.
@Suite("Review guide preparation and chat effort")
struct ReviewGuidePreparationTests {
    @Test("Text review prompts keep session closure learner-controlled")
    func textReviewClosureRequiresLearnerRequest() {
        #expect(Prompts.reviewTutor.contains("Do not say goodbye or tell the learner they are done unless they explicitly"))
        #expect(Prompts.reviewTutor.contains("Continue for as many turns or hours as the learner wants"))
        #expect(Prompts.appAssistant.contains("Never end a review, say goodbye"))
        #expect(Prompts.mcpServerInstructions.contains("Do not say goodbye, tell the learner they are done, or call end_review_session unless"))
    }

    @Test("Review questions are background work with a model of their own, not the chat's")
    func registersBackgroundTask() {
        let task = AITask.realtimeReviewPreparation
        #expect(task.displayName == "Review Questions")
        #expect(AITask.advancedTasks.contains(task))
        #expect(task.usesBackgroundModelDefault)
        #expect(!task.usesMultimodalBackgroundModelDefault)
        #expect(!task.followsChatRoute)
        #expect(KeychainService.canHaveOwnRoute(task))
        #expect(task.isBackgroundWork)
        #expect(task.usageNeed == .optional)
        #expect(CanonicalContentCleanupService.maxCandidatesPerDrain == 12)
        #expect(SourceListenableContentPreparationService.maxCandidatesPerDrain == 12)
        #expect(task.sourceType == nil, "written for every kind of source")
        #expect(task.defaultPrompt == Prompts.realtimeReviewPreparation)
        #expect(Prompts.realtimeReviewPreparation.contains("Strong answer"))
        #expect(Prompts.realtimeReviewPreparation.contains("Work exclusively from the supplied source text"))
        #expect(AIService.openRouterHostSlots(forTaskLabel: task.rawValue) == ["background.text"])
    }

    @Test("A chat's title and its history summary are Background tasks of their own")
    func chatPurposesHaveOwnRoutes() {
        // The raw values are the ledger labels both always had, so Activity
        // keeps one row for each across the change.
        #expect(AITask.chatTitle.rawValue == "chat_title")
        #expect(AITask.chatHistoryCompaction.rawValue == "chat_history_compaction")
        for task in [AITask.chatTitle, .chatHistoryCompaction] {
            #expect(AITask.advancedTasks.contains(task), "\(task.rawValue)")
            #expect(task.usesBackgroundModelDefault, "\(task.rawValue)")
            #expect(!task.followsChatRoute, "\(task.rawValue)")
            #expect(KeychainService.canHaveOwnRoute(task), "\(task.rawValue)")
            #expect(task.isBackgroundWork, "\(task.rawValue)")
            #expect(task.usageNeed == .needed, "\(task.rawValue)")
            #expect(task.sourceType == nil, "\(task.rawValue)")
            #expect(AIModelPreferenceKey.taskRoute(task) == "aiRoute.task.\(task.rawValue)")
        }
        #expect(AIUsageTaskLabel.text(for: "chat_title") == "Create Chat Title")
        // The work the learner waits on in a chat stays on the chat's model.
        #expect(AITask.deepResearch.followsChatRoute)
        #expect(AITask.sourceDiscovery.followsChatRoute)
    }

    @Test("An effort picked on a chat still on the Settings default is kept")
    func chatEffortSurvivesWithoutAModelPick() {
        let chatTask = AITask.chat
        let originalProvider = KeychainService.taskProvider(chatTask)
        let originalModel = KeychainService.taskModel(chatTask)
        let originalEffort = KeychainService.taskEffort(chatTask)
        let originalSpeed = KeychainService.taskSpeed(chatTask)
        let originalChosenEffort = KeychainService.chosenChatEffort
        defer {
            KeychainService.chosenChatEffort = originalChosenEffort
            KeychainService.resetChatSessionSelection()
            if let originalProvider, let originalModel {
                KeychainService.setTaskRoute(
                    provider: originalProvider,
                    model: originalModel,
                    effort: originalEffort,
                    speed: originalSpeed,
                    for: chatTask
                )
            }
        }

        // A fresh chat: no model picked from the chat bar, so the session
        // route is empty and the chat follows the Settings default. No effort
        // has been chosen from the chat bar either.
        KeychainService.chosenChatEffort = nil
        KeychainService.resetChatSessionSelection()
        let defaultSelection = KeychainService.resolvedSelection(for: chatTask)
        #expect(KeychainService.taskEffort(chatTask) == nil)

        // The effort chip's pick used to vanish here: it landed on a route that
        // named no model, which reads back as no route at all.
        KeychainService.setTaskEffort(.high, for: chatTask)
        #expect(KeychainService.taskEffort(chatTask) == .high)

        // Pinning the default keeps the chat on the model it was already using.
        let pinned = KeychainService.resolvedSelection(for: chatTask)
        #expect(pinned.provider == defaultSelection.provider)
        #expect(pinned.model == defaultSelection.model)

        // Speed behaves the same way, and clearing tuning never pins a model.
        KeychainService.resetChatSessionSelection()
        KeychainService.setTaskEffort(nil, for: chatTask)
        KeychainService.setTaskSpeed(.standard, for: chatTask)
        #expect(KeychainService.taskProvider(chatTask) == nil)
        KeychainService.setTaskSpeed(.fast, for: chatTask)
        #expect(KeychainService.taskSpeed(chatTask) == .fast)

        // Leaving the chat drops the pick, as every session-scoped pick does.
        KeychainService.resetChatSessionSelection()
        #expect(KeychainService.taskEffort(chatTask) == nil)
        #expect(KeychainService.taskSpeed(chatTask) == nil)
    }

    @Test("A new chat starts on the effort last chosen from the chat bar")
    func newChatStartsOnChosenEffort() {
        let chatTask = AITask.chat
        let originalProvider = KeychainService.taskProvider(chatTask)
        let originalModel = KeychainService.taskModel(chatTask)
        let originalEffort = KeychainService.taskEffort(chatTask)
        let originalSpeed = KeychainService.taskSpeed(chatTask)
        let originalChosenEffort = KeychainService.chosenChatEffort
        defer {
            KeychainService.chosenChatEffort = originalChosenEffort
            KeychainService.resetChatSessionSelection()
            if let originalProvider, let originalModel {
                KeychainService.setTaskRoute(
                    provider: originalProvider,
                    model: originalModel,
                    effort: originalEffort,
                    speed: originalSpeed,
                    for: chatTask
                )
            }
        }

        KeychainService.chosenChatEffort = nil
        KeychainService.resetChatSessionSelection()
        let selection = KeychainService.resolvedSelection(for: chatTask)
        let slug = OpenRouterModelID.slug(provider: selection.provider, model: selection.model).lowercased()
        // The Settings default, listed the way OpenRouter lists GLM 5.3
        // Flash: low, high and max, running at max when no effort is sent.
        let offersLow = [slug: OpenRouterReasoningEfforts(efforts: ["low", "high", "max"], defaultEffort: "max")]
        let lacksLow = [slug: OpenRouterReasoningEfforts(efforts: ["high", "max"], defaultEffort: "max")]

        AIModelCatalog.$openRouterReasoningEffortsOverride.withValue(offersLow) {
            #expect(KeychainService.taskEffort(chatTask) == nil)

            // Low picked in one chat is where the next one starts.
            KeychainService.chosenChatEffort = .low
            #expect(KeychainService.taskEffort(chatTask) == .low)

            // A chat's own effort outranks it for that chat only.
            KeychainService.setTaskEffort(.high, for: chatTask)
            #expect(KeychainService.taskEffort(chatTask) == .high)
            KeychainService.resetChatSessionSelection()
            #expect(KeychainService.taskEffort(chatTask) == .low)
        }

        // A model that does not offer the chosen effort runs on its own
        // default, and the choice waits for a model that does.
        AIModelCatalog.$openRouterReasoningEffortsOverride.withValue(lacksLow) {
            #expect(KeychainService.taskEffort(chatTask) == nil)
            #expect(KeychainService.chosenChatEffort == .low)
        }
    }

    @Test("A new chat starts on the speed last chosen from the chat bar")
    func newChatStartsOnChosenSpeed() {
        let chatTask = AITask.chat
        let originalProvider = KeychainService.taskProvider(chatTask)
        let originalModel = KeychainService.taskModel(chatTask)
        let originalEffort = KeychainService.taskEffort(chatTask)
        let originalSpeed = KeychainService.taskSpeed(chatTask)
        let originalChosenSpeed = KeychainService.chosenChatSpeed
        defer {
            KeychainService.chosenChatSpeed = originalChosenSpeed
            KeychainService.resetChatSessionSelection()
            if let originalProvider, let originalModel {
                KeychainService.setTaskRoute(
                    provider: originalProvider,
                    model: originalModel,
                    effort: originalEffort,
                    speed: originalSpeed,
                    for: chatTask
                )
            }
        }

        KeychainService.chosenChatSpeed = nil
        KeychainService.resetChatSessionSelection()
        let selection = KeychainService.resolvedSelection(for: chatTask)
        guard let slug = AIRequestOptionSupport.openRouterSpeedSlug(
            provider: selection.provider, model: selection.model, routingMode: KeychainService.textRoutingMode
        ) else { return }
        let vendor = String(slug.split(separator: "/").first ?? "")
        func tier(_ tag: String) -> OpenRouterEndpointTier {
            OpenRouterEndpointTier(
                tag: tag, providerName: vendor, inputUSDPerMTokens: 1, outputUSDPerMTokens: 4,
                cachedInputUSDPerMTokens: nil, discount: nil
            )
        }
        #expect(KeychainService.taskSpeed(chatTask) == nil)

        // Fast picked in one chat is where the next one starts.
        OpenRouterEndpointTierCatalog.cache([tier(vendor), tier(vendor + "/fast")], for: slug)
        KeychainService.chosenChatSpeed = .fast
        #expect(KeychainService.taskSpeed(chatTask) == .fast)
        KeychainService.resetChatSessionSelection()
        #expect(KeychainService.taskSpeed(chatTask) == .fast)

        // Standard is stored as no choice at all.
        KeychainService.chosenChatSpeed = .standard
        #expect(KeychainService.chosenChatSpeed == nil)
        #expect(KeychainService.taskSpeed(chatTask) == nil)

        // A model OpenRouter lists without the tier runs at standard speed,
        // and the choice waits for a model that has it.
        KeychainService.chosenChatSpeed = .fast
        OpenRouterEndpointTierCatalog.cache([tier(vendor)], for: slug)
        #expect(KeychainService.taskSpeed(chatTask) == nil)
        #expect(KeychainService.chosenChatSpeed == .fast)
        OpenRouterEndpointTierCatalog.clearCacheForTesting()
    }
}
