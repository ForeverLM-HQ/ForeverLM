import Foundation

/// The `DayPlan` CloudKit record: the day and every row it holds, current or
/// not. Tombstones travel too, so a block deleted or replaced on one Mac is
/// never brought back by the other.
///
/// This lives beside the models rather than in `KnowledgeStore+DayPlans`:
/// Foundation only, no SQLite. The phone no longer reads it; its running bout
/// and the break it earned come from the replica.
struct CloudKitDayPlanPayload: Codable, Sendable {
    let plan: DayPlan
    let blocks: [TimeBlock]
    /// The day's log. Absent on a record written before build 94, and by a
    /// client that never recorded any: an empty list either way.
    let activities: [DayActivity]
    /// The day's timed bouts and their write-ups. Absent on a record written
    /// before the bout timer shipped.
    let bouts: [LearningBout]

    init(
        plan: DayPlan,
        blocks: [TimeBlock] = [],
        activities: [DayActivity] = [],
        bouts: [LearningBout] = []
    ) {
        self.plan = plan
        self.blocks = blocks
        self.activities = activities
        self.bouts = bouts
    }

    private enum CodingKeys: String, CodingKey {
        case plan
        case blocks
        case activities
        case bouts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        plan = try container.decode(DayPlan.self, forKey: .plan)
        blocks = try container.decodeIfPresent([TimeBlock].self, forKey: .blocks) ?? []
        activities = try container.decodeIfPresent([DayActivity].self, forKey: .activities) ?? []
        bouts = try container.decodeIfPresent([LearningBout].self, forKey: .bouts) ?? []
    }
}
