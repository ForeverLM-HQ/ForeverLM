import Foundation

struct SchedulePlanItem: Identifiable, Equatable {
    let id: String
    let sourceID: String
    let title: String
    let subtitle: String
    let groupTitle: String?
    let plannedDate: Date
    let isCompleted: Bool
    let canMarkDone: Bool
    let hasLinkedChat: Bool
    let isMissingSource: Bool
    /// Reading/listening/chat/review activity recorded on this row's planned
    /// day. A hint that the source has been touched — never proof of completion.
    var activityKinds: Set<SourceActivityKind> = []
    /// Goals this shared placement is tagged with (a source can serve several goals).
    var goalTags: [GoalTag] = []
}

struct ScheduleDay: Identifiable, Equatable {
    let date: Date
    let items: [SchedulePlanItem]
    let isToday: Bool
    let isPast: Bool

    var id: Date { date }
    var pendingCount: Int { items.filter { !$0.isCompleted }.count }
    var completedCount: Int { items.filter(\.isCompleted).count }
}
