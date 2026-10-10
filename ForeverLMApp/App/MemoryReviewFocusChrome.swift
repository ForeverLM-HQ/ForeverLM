import SwiftUI

/// What a memory review in focus puts on its chrome line: the way out. Shared
/// by the card review (`MemoryCardSessionView`) and a day's review chat
/// (`InternalReviewPanel`), so the × reads and behaves alike in both.
///
/// No clock is drawn (product owner, 2026-10-04: "remove this timer"). The day's
/// goal still counts only while the learner is actually in the review
/// (`MemoryReviewEngagementTracker`); it is just not shown. The × is the only
/// way back to the workspace, which is the point: a review that can be
/// stepped out of by clicking anything else is not the fifteen minutes it
/// was meant to be. While leaving would end today's session, the × says so
/// before it does (product owner, 2026-09-19: "i can also quit but then the memory
/// session is over"); otherwise it is a plain way out.
struct MemoryReviewFocusChrome: View {
    /// Whether the controls hang in the titlebar band, where a plain
    /// SwiftUI button gets no click (`ChatHeaderControlButton`).
    let onTitlebarBand: Bool
    let controlSize: CGFloat
    /// Whether leaving now ends today's session, which the × asks about.
    let leavingEnds: Bool
    /// Prefix of the control's accessibility identifier: `<prefix>Leave`.
    var identifierPrefix: String = "mac.chatMemoryFocus"
    let leave: () -> Void

    @State private var isConfirmingEnd = false

    private var goalTracker: MemoryReviewEngagementTracker { MemoryReviewEngagementTracker.shared }

    var body: some View {
        let goal = goalTracker.snapshot
        HStack(spacing: StudioPaneClosePlacement.interControlSpacing) {
            ChatHeaderControlButton(
                onTitlebarBand: onTitlebarBand,
                controlSize: controlSize,
                help: leavingEnds
                    ? "End today's review. Leaving early ends the session for the day."
                    : "Leave the review and bring the workspace back",
                accessibilityLabel: leavingEnds ? "End review" : "Leave review",
                accessibilityIdentifier: "\(identifierPrefix)Leave",
                action: {
                    if leavingEnds {
                        isConfirmingEnd = true
                    } else {
                        leave()
                    }
                }
            ) {
                Image(systemName: "xmark")
                    .zoomedSystemFont(size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
            }
            .alert("End today's review?", isPresented: $isConfirmingEnd) {
                Button("End Session", role: .destructive, action: leave)
                Button("Keep Going", role: .cancel) {}
            } message: {
                Text(Self.endReviewMessage(
                    budgetMinutes: MemoryReviewBudget.minutes,
                    remainingSeconds: goal.today.remainingSeconds
                ))
            }
        }
    }

    /// What the × asks before it ends the session: the promise, what is left
    /// of it, and what ending means. One sentence each.
    static func endReviewMessage(budgetMinutes: Int, remainingSeconds: TimeInterval) -> String {
        "You committed to \(MemoryReviewBudget.label(budgetMinutes)), and \(MemoryReviewGoal.remainingLabel(seconds: remainingSeconds)) is still to go. Ending now ends today's session: the next review is tomorrow's."
    }
}
