import Foundation
import Testing
@testable import ForeverLM

/// Generation 2's memory recorders through the app's own writers (WP13): an attempt joins this device's
/// Sitting, source activity and the review clock go into this Mac's log, a kept quiz score and a deck's
/// state row become records, and a bout is a Sitting. Generation 1's writers write what build 177 does.
@Suite("Memory generation-2 recorders")
struct MemoryGeneration2RecorderTests {
    private typealias F = MemorySyncFixture

    private static func source(_ store: KnowledgeStore) throws -> String {
        var article = StudioArticle(url: "https://example.org/memory/recorders", title: "Complex I", sourceType: .article)
        _ = try store.insertSourceIfNew(&article)
        return article.id
    }

    private static func item(_ sourceID: String, createdAt: Date) -> MemoryItem {
        MemoryItem(
            id: "item-1", kind: .concept, target: "Four protons per NADH", rubricJSON: "{}",
            sources: [MemoryItemSource(id: "anchor-1", memoryItemID: "item-1", sourceID: sourceID, excerpt: "pumps", sourceSHA256: "abc", sortIndex: 0)],
            createdAt: createdAt, updatedAt: createdAt
        )
    }

    private static func xml(_ value: Any) throws -> String {
        try #require(PreferenceStore.encodePlist(value))
    }

    @Test("Each writer records into the memory records once the store is activated for generation 2")
    func generation2() throws {
        let (root, store) = try F.makeStore("recorders")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceID = try Self.source(store)
        let now = Date()
        try store.saveMemoryItem(Self.item(sourceID, createdAt: now.addingTimeInterval(-3 * 86_400)))
        #expect(try store.recordMemoryAttempt(MemoryAttempt(
            id: "attempt-1", memoryItemID: "item-1", prompt: "How many?", learnerAnswer: "Four", score: 1, scheduleRating: .good,
            gradeState: .graded, attemptedAt: now
        )))
        let sittingID = try #require(try F.text(store, "SELECT sitting_id FROM memory_sitting_answers WHERE answer_id = 'attempt-1'"))
        #expect(try F.text(store, "SELECT kind || '|' || device_id FROM memory_sittings WHERE id = ?", [.text(sittingID)]) == "cards|\(F.deviceID)")

        try store.recordScheduledSourceActivity(sourceID: sourceID, on: now, kind: .reading, fraction: 0.5, engagedSeconds: 45)
        let log = try #require(try store.loadDeviceActivityLog(day: DayPlan.dateString(for: now), deviceID: F.deviceID))
        #expect(log.sources[sourceID]?["engagedSeconds"] == 45)
        try store.recordMemoryReviewActivity(MemoryReviewActivity(day: DayPlan.dateString(for: now), deviceID: "uuid-1", activeSeconds: 120,
                                                                  goalSeconds: 600, updatedAt: now))
        #expect(try store.loadDeviceActivityLog(day: DayPlan.dateString(for: now), deviceID: F.deviceID)?.review?["seconds"] == 120)

        try store.writePreference(key: "courseQuiz.score.cq-1", valuePlistXML: try Self.xml(["right": 4, "total": 4, "takenAt": now.timeIntervalSince1970]))
        #expect(try F.text(store, "SELECT kind || '|' || scope_json FROM memory_sittings WHERE kind = 'courseQuiz'") == "courseQuiz|{\"quizID\":\"cq-1\"}")
        var deck = MemoryCardDeckState()
        deck.markKept(cardID: "c-1", memoryItemID: "item-1", seed: "walk:\(sourceID)#q1", at: now)
        try store.writePreference(key: MemoryCardDeckState.preferenceKey(deckID: "carddeck-\(sourceID)"), valuePlistXML: try Self.xml(deck.preferenceValue))
        #expect(try F.text(store, "SELECT seed_key FROM memory_card_states WHERE card_id = 'item-1'") == "walk:\(sourceID)#q1")

        let bout = try store.startLearningBout(LearningBout(dayPlanID: DayPlan.dateString(for: now), title: "Complex I"), now: now)
        let pending = try F.pending(store)
        #expect(F.fields(pending["Sitting:\(bout.id)"])?["kind"] == "bout")
        #expect(F.fields(pending["Sitting:\(sittingID)"])?["answers"]?["attempt-1"]?["rating"] == "good")
        #expect(F.fields(pending["Card:item-1"])?["status"] == "kept")
    }

    @Test("Under generation 1 the same writers fill none of the memory records")
    func generation1() throws {
        let root = try Schema154Fixture.temporaryRoot("recorders-g1")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        let sourceID = try Self.source(store)
        let now = Date()
        try store.saveMemoryItem(Self.item(sourceID, createdAt: now.addingTimeInterval(-3 * 86_400)))
        _ = try store.recordMemoryAttempt(MemoryAttempt(id: "attempt-1", memoryItemID: "item-1", prompt: "Q", learnerAnswer: "A",
                                                        score: 1, scheduleRating: .good, gradeState: .graded, attemptedAt: now))
        try store.recordScheduledSourceActivity(sourceID: sourceID, on: now, kind: .reading, fraction: 0.5, engagedSeconds: 45)
        try store.writePreference(key: "courseQuiz.score.cq-1", valuePlistXML: try Self.xml(["right": 4, "total": 4, "takenAt": now.timeIntervalSince1970]))
        for table in KnowledgeStore.memorySyncTables.map(\.name) {
            #expect(try F.count(store, "SELECT COUNT(*) FROM \(table)") == 0, "\(table)")
        }
        #expect(try F.count(store, "SELECT COUNT(*) FROM memory_attempts") == 1)
    }
}
