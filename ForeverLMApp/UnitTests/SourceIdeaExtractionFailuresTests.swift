import Foundation
import Testing
@testable import ForeverLM

/// A source the model could not turn into ideas is remembered for a day, per
/// text, so the Memory row stops billing the same failing call on every click.
@Suite("Source idea extraction failure memory")
struct SourceIdeaExtractionFailuresTests {

    private func makeDefaults() -> UserDefaults {
        let suite = "foreverlm-extraction-failures-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("A recorded failure is remembered for the same text within the day, and forgotten after it")
    func failureIsRememberedForADay() {
        let defaults = makeDefaults()
        let failedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        SourceIdeaExtractionFailures.record(
            sourceID: "src", contentHash: "abc", message: "Invalid AI response",
            now: failedAt, defaults: defaults
        )

        let soon = failedAt.addingTimeInterval(60 * 60)
        let remembered = SourceIdeaExtractionFailures.recent(sourceID: "src", contentHash: "abc", now: soon, defaults: defaults)
        #expect(remembered?.message == "Invalid AI response")
        #expect(remembered?.contentHash == "abc")

        let nextDay = failedAt.addingTimeInterval(SourceIdeaExtractionFailures.retryInterval + 1)
        #expect(SourceIdeaExtractionFailures.recent(sourceID: "src", contentHash: "abc", now: nextDay, defaults: defaults) == nil)
    }

    @Test("A change to the text clears the way: the failure was about the old text")
    func differentTextIsTried() {
        let defaults = makeDefaults()
        let failedAt = Date()
        SourceIdeaExtractionFailures.record(
            sourceID: "src", contentHash: "abc", message: "No ideas", now: failedAt, defaults: defaults
        )
        #expect(SourceIdeaExtractionFailures.recent(sourceID: "src", contentHash: "def", now: failedAt, defaults: defaults) == nil)
        #expect(SourceIdeaExtractionFailures.recent(sourceID: "other", contentHash: "abc", now: failedAt, defaults: defaults) == nil)
    }

    @Test("A success clears the record")
    func successClears() {
        let defaults = makeDefaults()
        SourceIdeaExtractionFailures.record(sourceID: "src", contentHash: "abc", message: "x", defaults: defaults)
        SourceIdeaExtractionFailures.clear(sourceID: "src", defaults: defaults)
        #expect(SourceIdeaExtractionFailures.recent(sourceID: "src", contentHash: "abc", defaults: defaults) == nil)
    }

    @Test("Only the model's answer counts as a hard failure; the connection does not")
    func hardFailureClassification() {
        #expect(SourceIdeaExtractionFailures.isHardFailure(AIError.invalidResponse))
        #expect(SourceIdeaExtractionFailures.isHardFailure(SourceIdeaExtractionError.noIdeas("Evo 2")))
        #expect(!SourceIdeaExtractionFailures.isHardFailure(SourceIdeaExtractionError.noReadableText("Gamma")))
        #expect(!SourceIdeaExtractionFailures.isHardFailure(SourceIdeaExtractionError.noConfiguredModel))
        #expect(!SourceIdeaExtractionFailures.isHardFailure(AIError.httpError(status: 429, message: "slow down", retryAfterSeconds: 5)))
        #expect(!SourceIdeaExtractionFailures.isHardFailure(URLError(.notConnectedToInternet)))
    }

    @Test("Expired entries are pruned on the next write")
    func pruningDropsExpiredEntries() {
        let defaults = makeDefaults()
        let old = Date(timeIntervalSinceReferenceDate: 800_000_000)
        SourceIdeaExtractionFailures.record(sourceID: "old", contentHash: "a", message: "x", now: old, defaults: defaults)
        let later = old.addingTimeInterval(SourceIdeaExtractionFailures.retryInterval + 10)
        SourceIdeaExtractionFailures.record(sourceID: "new", contentHash: "b", message: "y", now: later, defaults: defaults)

        let entries = defaults.dictionary(forKey: SourceIdeaExtractionFailures.key) as? [String: [String: Any]] ?? [:]
        #expect(entries.keys.sorted() == ["new"])
    }
}
