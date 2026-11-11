import Foundation
import Testing
@testable import ForeverLM

/// The phone's half of the Planner's timer: the widget's snapshot of the bout.
/// See docs/planner-design.md, "The phone's clock".
@Suite("Mobile learning bout store")
struct MobileLearningBoutStoreTests {

    @Test("The widget's two writers each keep the other's half of the snapshot")
    func snapshotWritersDoNotBlankEachOther() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let empty = MobileTodayWidgetSnapshot(pendingCount: 0, nextTitle: nil, updatedAt: .distantPast)

        let withDay = MobileTodayWidgetSnapshotStore.replacingDay(
            in: empty, pendingCount: 3, nextTitle: "A paper", memoryDueCount: 2, memoryNewCount: 4, now: now
        )
        let withBout = MobileTodayWidgetSnapshotStore.replacingBout(
            in: withDay, title: "GDF15", endsAt: now.addingTimeInterval(600), isOnBreak: true, needsAttention: false, now: now
        )
        #expect(withBout.pendingCount == 3, "the bout's write kept the day's counts")
        #expect(withBout.memoryDueCount == 2)
        #expect(withBout.memoryNewCount == 4)
        #expect(withBout.memoryCardCount == 6)
        #expect(withBout.boutTitle == "GDF15")
        #expect(withBout.isOnBreak)
        #expect(withBout.hasRunningBoutClock(now: now))
        // A clock that has run out draws nothing rather than a stale countdown.
        #expect(!withBout.hasRunningBoutClock(now: now.addingTimeInterval(1_200)))

        let redrawnDay = MobileTodayWidgetSnapshotStore.replacingDay(
            in: withBout, pendingCount: 1, nextTitle: "Another", memoryDueCount: 0, memoryNewCount: 0, now: now
        )
        #expect(redrawnDay.pendingCount == 1)
        #expect(redrawnDay.boutTitle == "GDF15", "the day's write kept the bout's clock")
        #expect(redrawnDay.isOnBreak)

        let cleared = MobileTodayWidgetSnapshotStore.replacingBout(
            in: redrawnDay, title: nil, endsAt: nil, isOnBreak: false, needsAttention: false, now: now
        )
        #expect(cleared.boutTitle == nil)
        #expect(!cleared.hasRunningBoutClock(now: now))
        #expect(cleared.pendingCount == 1)
    }

    @Test("A snapshot written before the bout's clock existed decodes with no bout, and without the card it named")
    func olderSnapshotDecodes() throws {
        let older = try PropertyListDecoder().decode(
            MobileTodayWidgetSnapshot.self,
            from: try PropertyListEncoder().encode(SnapshotWithoutBoutClock(
                pendingCount: 2, nextTitle: "A paper", memoryDueCount: 3, nextMemoryTarget: "Retrieval", updatedAt: Date()
            ))
        )
        #expect(older.pendingCount == 2)
        #expect(older.boutTitle == nil)
        #expect(!older.isOnBreak)
        #expect(!older.boutNeedsAttention)
        // The card's target was its answer; the widget now draws counts only.
        #expect(older.memoryDueCount == 3)
        #expect(older.memoryNewCount == 0)
    }

    /// The shape the app group held before the bout's clock was added to it,
    /// when the widget still named the next card by its target.
    private struct SnapshotWithoutBoutClock: Encodable {
        let pendingCount: Int
        let nextTitle: String?
        let memoryDueCount: Int
        let nextMemoryTarget: String?
        let updatedAt: Date
    }
}
