import Foundation

/// What the phone's widget draws, written into the shared app group by the app
/// and read by the extension.
///
/// Every field is a plain value — no model types — because the widget target
/// compiles this file and nothing else of the library. The bout's clock is
/// three of them: what it is called, when it runs out, and whether it is the
/// learning or the break, which is all a self-ticking countdown needs.
struct MobileTodayWidgetSnapshot: Codable, Equatable, Sendable {
    let pendingCount: Int
    let nextTitle: String?
    /// What today's card review holds, as counts only: a card's stored
    /// target is its answer, so the widget never names a card.
    /// `memoryDueCount` is the cards seen before that are due and
    /// `memoryNewCount` the new cards, both as the phone's card review deals
    /// them (`MemoryCardQueue.today`), which the widget's tap opens.
    let memoryDueCount: Int
    let memoryNewCount: Int
    /// The live bout's title, when one is running. Nil the rest of the time,
    /// which is what tells the widget to draw the day instead.
    let boutTitle: String?
    /// When the clock the widget should draw runs out: the bout's own timer
    /// while learning, the break's while resting. Nil when the bout is waiting
    /// on its write-up or its break, which have no clock of their own.
    let boutEndsAt: Date?
    /// Whether that clock is the break's. The break is the reason this is on
    /// the phone at all, so it is drawn differently.
    let isOnBreak: Bool
    /// The learner owes a write-up, or has earned a break and not taken it —
    /// a bout that is live with no clock running.
    let boutNeedsAttention: Bool
    let updatedAt: Date

    init(
        pendingCount: Int,
        nextTitle: String?,
        memoryDueCount: Int = 0,
        memoryNewCount: Int = 0,
        boutTitle: String? = nil,
        boutEndsAt: Date? = nil,
        isOnBreak: Bool = false,
        boutNeedsAttention: Bool = false,
        updatedAt: Date
    ) {
        self.pendingCount = pendingCount
        self.nextTitle = nextTitle
        self.memoryDueCount = memoryDueCount
        self.memoryNewCount = memoryNewCount
        self.boutTitle = boutTitle
        self.boutEndsAt = boutEndsAt
        self.isOnBreak = isOnBreak
        self.boutNeedsAttention = boutNeedsAttention
        self.updatedAt = updatedAt
    }

    /// Every card in today's review.
    var memoryCardCount: Int { memoryDueCount + memoryNewCount }

    /// What today's review is made of, never a card: "6 due · 4 new",
    /// "6 due", "4 new cards", as the Mac's Memory pane says it.
    var memoryLine: String {
        switch (memoryDueCount > 0, memoryNewCount > 0) {
        case (true, true): return "\(memoryDueCount) due · \(memoryNewCount) new"
        case (true, false): return "\(memoryDueCount) due"
        case (false, true): return memoryNewCount == 1 ? "1 new card" : "\(memoryNewCount) new cards"
        case (false, false): return "Nothing due today"
        }
    }

    /// Whether the bout's clock is still ahead of `now`. A snapshot the app has
    /// not refreshed since the break ended must draw nothing rather than a
    /// countdown that finished an hour ago.
    func hasRunningBoutClock(now: Date = Date()) -> Bool {
        guard boutTitle != nil, let boutEndsAt else { return false }
        return boutEndsAt > now
    }

    private enum CodingKeys: String, CodingKey {
        case pendingCount
        case nextTitle
        case memoryDueCount
        case memoryNewCount
        case boutTitle
        case boutEndsAt
        case isOnBreak
        case boutNeedsAttention
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pendingCount = try values.decode(Int.self, forKey: .pendingCount)
        nextTitle = try values.decodeIfPresent(String.self, forKey: .nextTitle)
        memoryDueCount = try values.decodeIfPresent(Int.self, forKey: .memoryDueCount) ?? 0
        memoryNewCount = try values.decodeIfPresent(Int.self, forKey: .memoryNewCount) ?? 0
        boutTitle = try values.decodeIfPresent(String.self, forKey: .boutTitle)
        boutEndsAt = try values.decodeIfPresent(Date.self, forKey: .boutEndsAt)
        isOnBreak = try values.decodeIfPresent(Bool.self, forKey: .isOnBreak) ?? false
        boutNeedsAttention = try values.decodeIfPresent(Bool.self, forKey: .boutNeedsAttention) ?? false
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    }
}

enum MobileTodayWidgetSnapshotStore {
    static let suiteName = "group.com.foreverlm"
    private static let key = "widget.today.snapshot"

    static func save(_ snapshot: MobileTodayWidgetSnapshot) {
        guard let data = try? PropertyListEncoder().encode(snapshot) else { return }
        UserDefaults(suiteName: suiteName)?.set(data, forKey: key)
    }

    static func load() -> MobileTodayWidgetSnapshot {
        guard let data = UserDefaults(suiteName: suiteName)?.data(forKey: key),
              let value = try? PropertyListDecoder().decode(MobileTodayWidgetSnapshot.self, from: data) else {
            return MobileTodayWidgetSnapshot(
                pendingCount: 0,
                nextTitle: nil,
                memoryDueCount: 0,
                memoryNewCount: 0,
                updatedAt: .distantPast
            )
        }
        return value
    }

    /// Replaces only the day's counts, keeping whatever the bout's clock last
    /// wrote. The other half of `saveBout`.
    static func saveDay(
        pendingCount: Int,
        nextTitle: String?,
        memoryDueCount: Int,
        memoryNewCount: Int,
        now: Date = Date()
    ) {
        save(replacingDay(
            in: load(),
            pendingCount: pendingCount,
            nextTitle: nextTitle,
            memoryDueCount: memoryDueCount,
            memoryNewCount: memoryNewCount,
            now: now
        ))
    }

    /// Replaces only the bout's part of the snapshot, keeping the day's counts
    /// as the catalog last wrote them.
    static func saveBout(
        title: String?,
        endsAt: Date?,
        isOnBreak: Bool,
        needsAttention: Bool,
        now: Date = Date()
    ) {
        save(replacingBout(
            in: load(),
            title: title,
            endsAt: endsAt,
            isOnBreak: isOnBreak,
            needsAttention: needsAttention,
            now: now
        ))
    }

    // MARK: - The two halves

    /// Two writers share this one record — the library's projections and the
    /// bout's clock — and neither may blank the other's half. Both rules are
    /// pure so they can be pinned without an app group, which a test host does
    /// not always have.
    static func replacingDay(
        in existing: MobileTodayWidgetSnapshot,
        pendingCount: Int,
        nextTitle: String?,
        memoryDueCount: Int,
        memoryNewCount: Int,
        now: Date
    ) -> MobileTodayWidgetSnapshot {
        MobileTodayWidgetSnapshot(
            pendingCount: pendingCount,
            nextTitle: nextTitle,
            memoryDueCount: memoryDueCount,
            memoryNewCount: memoryNewCount,
            boutTitle: existing.boutTitle,
            boutEndsAt: existing.boutEndsAt,
            isOnBreak: existing.isOnBreak,
            boutNeedsAttention: existing.boutNeedsAttention,
            updatedAt: now
        )
    }

    static func replacingBout(
        in existing: MobileTodayWidgetSnapshot,
        title: String?,
        endsAt: Date?,
        isOnBreak: Bool,
        needsAttention: Bool,
        now: Date
    ) -> MobileTodayWidgetSnapshot {
        MobileTodayWidgetSnapshot(
            pendingCount: existing.pendingCount,
            nextTitle: existing.nextTitle,
            memoryDueCount: existing.memoryDueCount,
            memoryNewCount: existing.memoryNewCount,
            boutTitle: title,
            boutEndsAt: endsAt,
            isOnBreak: isOnBreak,
            boutNeedsAttention: needsAttention,
            updatedAt: now
        )
    }
}
