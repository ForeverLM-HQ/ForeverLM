import Foundation
import Testing
@testable import ForeverLM

/// Schema 98 dropped the retired method name from storage; what is left of it on a device is the model
/// choices stored under the retired task names, which move once to the new names.
@Suite("Review schema migration")
struct ReviewSchemaMigrationTests {
    @Test("Model choices stored under the retired task names move once to the new names")
    func retiredPreferenceKeysMoveOnce() throws {
        let suite = "foreverlm-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("openrouter", forKey: "aiTask.feynman_quiz.provider")
        defaults.set("anthropic/claude", forKey: "aiTask.feynman_quiz.model")
        defaults.set("kept", forKey: "aiRoute.task.chat")
        defaults.set("stale", forKey: "aiRoute.task.feynman_quiz")
        defaults.set("foundation", forKey: "feynman.grader.v1")

        #expect(LegacyIdentityAdoption.adoptRetiredMethodPreferenceKeysIfNeeded(defaults: defaults) == 3)
        #expect(defaults.string(forKey: "aiTask.chat.provider") == "openrouter")
        #expect(defaults.string(forKey: "aiTask.chat.model") == "anthropic/claude")
        // A value already chosen under the new name wins over the stale one.
        #expect(defaults.string(forKey: "aiRoute.task.chat") == "kept")
        #expect(defaults.string(forKey: "foreverlm.grader.v1") == "foundation")
        for old in ["aiTask.feynman_quiz.provider", "aiTask.feynman_quiz.model", "aiRoute.task.feynman_quiz", "feynman.grader.v1"] {
            #expect(defaults.object(forKey: old) == nil, "\(old) removed")
        }
        // Second launch: nothing to do, nothing re-moved.
        defaults.set("late", forKey: "aiTask.feynman_quiz.model")
        #expect(LegacyIdentityAdoption.adoptRetiredMethodPreferenceKeysIfNeeded(defaults: defaults) == 0)
        #expect(defaults.string(forKey: "aiTask.chat.model") == "anthropic/claude")
    }
}
