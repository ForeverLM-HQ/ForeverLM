import SwiftUI

/// The review plan's chip in the composer's tray, beside "in context", and
/// the popover it opens (`ChatReviewPlan`). The chip says where the review
/// stands; the popover holds the whole plan, the detours the chat has taken
/// from it with a way straight back, and what was parked for later (product
/// owner, 2026-11-17: "maybe the plan can be next to the chat box somehow? as
/// some kind of popup?").
struct ReviewPlanChip: View {
    let plan: ChatReviewPlan
    let earlierTitles: [String]
    /// Sends `ChatReviewPlan.backToPlanMessage`.
    let onBackToPlan: () -> Void
    /// Sends `ChatReviewPlan.goToTopicMessage` for the topic picked.
    let onGoToTopic: (Int, String) -> Void

    @State private var isPresented = false
    @State private var isHovering = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "list.bullet.clipboard")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(plan.isOnDetour ? Color.orange : Color.accentColor)
                Text(plan.progressLabel)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                if plan.isOnDetour {
                    Text("· off plan")
                        .foregroundStyle(.orange)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.callout)
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(Color.primary.opacity(isPresented ? 0.09 : (isHovering ? 0.06 : 0)))
            )
            .contentShape(Capsule())
        }
        // The chip paints its own hover capsule, as the "in context" pill does.
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.18), value: plan)
        .help("Show the review plan")
        .accessibilityLabel("Review plan, \(plan.progressLabel)\(plan.isOnDetour ? ", off plan" : "")")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            ReviewPlanPopover(
                plan: plan,
                earlierTitles: earlierTitles,
                onBackToPlan: {
                    isPresented = false
                    onBackToPlan()
                },
                onGoToTopic: { index, title in
                    isPresented = false
                    onGoToTopic(index, title)
                }
            )
        }
    }
}

private struct ReviewPlanPopover: View {
    let plan: ChatReviewPlan
    let earlierTitles: [String]
    let onBackToPlan: () -> Void
    let onGoToTopic: (Int, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(plan.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text("\(plan.doneTopics) of \(plan.topics.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if plan.isOnDetour || plan.openQuestion != nil {
                whereYouAre
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                Divider()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(plan.topics.enumerated()), id: \.offset) { index, topic in
                        topicRow(index: index, topic: topic)
                    }
                    if !plan.parked.isEmpty {
                        footnote(icon: "parkingsign.circle", title: "Parked", lines: plan.parked)
                            .padding(.top, 8)
                    }
                    if !earlierTitles.isEmpty {
                        footnote(icon: "clock.arrow.circlepath", title: "Earlier plans", lines: earlierTitles)
                            .padding(.top, 6)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
        }
        .frame(width: 380)
        .frame(maxHeight: 520)
    }

    /// The stack from the plan down to where the chat is now, the open
    /// question, and the way back.
    @ViewBuilder
    private var whereYouAre: some View {
        VStack(alignment: .leading, spacing: 8) {
            if plan.isOnDetour {
                let topicTitle = plan.activeTopicIndex.map { "\($0 + 1) \(plan.topics[$0].title)" }
                let stack = ["Plan"] + (topicTitle.map { [$0] } ?? []) + plan.detours
                Text(stack.joined(separator: "  ›  "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let question = plan.openQuestion {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                    Text(question)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
            }
            if plan.isOnDetour {
                Button(action: onBackToPlan) {
                    Label("Back to plan", systemImage: "arrow.uturn.backward")
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(.hoverWash(opacity: 0.12))
                .padding(.leading, 5)
                .help("Leave the detours and take up the open question")
            }
        }
    }

    private func topicRow(index: Int, topic: ChatReviewPlan.Topic) -> some View {
        Button {
            onGoToTopic(index, topic.title)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    statusIcon(topic.status)
                    Text("\(index + 1)  \(topic.title)")
                        .font(.callout.weight(topic.status == .active ? .semibold : .regular))
                        .foregroundStyle(topic.status == .todo ? .secondary : .primary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 6)
                    if !topic.points.isEmpty {
                        Text("\(topic.donePoints)/\(topic.points.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                // Points show where the work is: the active topic, and any
                // topic left part-way.
                if topic.status == .active || (topic.status != .done && topic.points.contains(where: { $0.status != .todo })) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(topic.points.enumerated()), id: \.offset) { _, point in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                statusIcon(point.status).font(.caption2)
                                Text(point.text)
                                    .font(.caption)
                                    .foregroundStyle(point.status == .done ? .secondary : .primary)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.leading, 22)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(inset: 0))
        .help(topic.status == .active ? "The topic being worked on" : "Go to this topic")
    }

    private func statusIcon(_ status: ChatReviewPlan.Status) -> some View {
        let symbol: String
        let color: Color
        switch status {
        case .done: symbol = "checkmark.circle.fill"; color = .green
        case .active: symbol = "circle.inset.filled"; color = .accentColor
        case .partial: symbol = "circle.lefthalf.filled"; color = .orange
        case .skipped: symbol = "minus.circle"; color = .secondary
        case .todo: symbol = "circle"; color = .secondary
        }
        return Image(systemName: symbol)
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }

    private func footnote(icon: String, title: String, lines: [String]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon)
            Text("\(title): \(lines.joined(separator: " · "))")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
    }
}
