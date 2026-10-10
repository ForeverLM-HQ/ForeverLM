import Foundation
import Testing
@testable import ForeverLM

/// The review guide's preparation task and the chat effort it follows, and
/// the text review's closure rule. These lived with the Mac's realtime voice
/// tests until realtime voice went on 2026-10-01; the task
/// (`realtime_review_preparation`, a synced id) still writes the review
/// guides today's memory review reads.
@Suite("Review guide preparation and chat effort")
struct ReviewGuidePreparationTests {
    @Test("Text review prompts keep session closure learner-controlled")
    func textReviewClosureRequiresLearnerRequest() {
        #expect(Prompts.reviewTutor.contains("Do not say goodbye or tell the learner they are done unless they explicitly"))
        #expect(Prompts.reviewTutor.contains("Continue for as many turns or hours as the learner wants"))
        #expect(Prompts.appAssistant.contains("Never end a review, say goodbye"))
        #expect(Prompts.mcpServerInstructions.contains("Do not say goodbye, tell the learner they are done, or call end_review_session unless"))
    }

    @Test("Review preparation follows Chat instead of exposing another model setting")
    func registersChatModelTask() {
        #expect(!AITask.advancedTasks.contains(.realtimeReviewPreparation))
        #expect(!AITask.realtimeReviewPreparation.usesBackgroundModelDefault)
        #expect(CanonicalContentCleanupService.maxCandidatesPerDrain == 12)
        #expect(SourceListenableContentPreparationService.maxCandidatesPerDrain == 12)
        #expect(AITask.realtimeReviewPreparation.sourceType == .paper)
        #expect(AITask.realtimeReviewPreparation.defaultPrompt == Prompts.realtimeReviewPreparation)
        #expect(Prompts.realtimeReviewPreparation.contains("Strong answer"))
        #expect(Prompts.realtimeReviewPreparation.contains("Work exclusively from the supplied source text"))
    }

    @Test("Review preparation resolves the exact Chat provider and model")
    func resolvesSelectedChatModel() {
        let chatTask = AITask.chat
        let originalProvider = KeychainService.taskProvider(chatTask)
        let originalModel = KeychainService.taskModel(chatTask)
        let originalEffort = KeychainService.taskEffort(chatTask)
        let originalSpeed = KeychainService.taskSpeed(chatTask)
        defer {
            KeychainService.setTaskProvider(originalProvider, for: chatTask)
            KeychainService.setTaskModel(originalModel, for: chatTask)
            KeychainService.setTaskEffort(originalEffort, for: chatTask)
            KeychainService.setTaskSpeed(originalSpeed, for: chatTask)
        }

        KeychainService.setTaskProvider(.openRouter, for: chatTask)
        KeychainService.setTaskModel("meta-llama/llama-4-maverick", for: chatTask)
        KeychainService.setTaskEffort(.high, for: chatTask)
        KeychainService.setTaskSpeed(.fast, for: chatTask)

        let reviewSelection = KeychainService.resolvedSelection(for: .realtimeReviewPreparation)
        let chatSelection = KeychainService.resolvedSelection(for: .chat)
        #expect(reviewSelection.provider == chatSelection.provider)
        #expect(reviewSelection.model == chatSelection.model)
        #expect(
            KeychainService.taskEffort(.realtimeReviewPreparation)
                == KeychainService.taskEffort(.chat)
        )
        #expect(
            KeychainService.taskSpeed(.realtimeReviewPreparation)
                == KeychainService.taskSpeed(.chat)
        )
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
}
