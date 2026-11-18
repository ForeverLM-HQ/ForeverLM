import SwiftUI

/// The review plan's chip in the composer's tray, beside "in context", and
/// the popover it opens (`ChatReviewPlan`). The chip says where the review
/// stands; the popover holds the whole plan, the detours the chat has taken
/// from it with a way straight back, and what was parked for later (product
/// owner, 2026-11-17: "maybe the plan can be next to the chat box somehow? as
/// some kind of popup?").
///
/// One accent, for the topic being worked on; everything else is ink and
/// grey (product owner, 2026-11-17: "i don't love this design; can you make
/// it look nicer?"). Only the active topic shows its points; any other opens
/// with a click.
struct ReviewPlanChip: View {
    let plan: ChatReviewPlan
    let earlierTitles: [String]
    /// Sends `ChatReviewPlan.backToPlanMessage`.
    let onBackToPlan: () -> Void
    /// Sends `ChatReviewPlan.goToTopicMessage` for the topic picked.
    let onGoToTopic: (Int, String) -> Void
    /// Takes the plan out of the chat (`ReviewSessionManager.clearReviewPlan`).
    let onClear: () -> Void

    @State private var isPresented = false
    @State private var isHovering = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                ReviewPlanRing(progress: overallProgress, tint: plan.isOnDetour ? .orange : .accentColor)
                    .frame(width: 13, height: 13)
                Text(plan.progressLabel)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                if plan.isOnDetour {
                    Text("Off plan")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.callout)
            .padding(.horizontal, 5)
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
                },
                onClear: {
                    isPresented = false
                    onClear()
                }
            )
        }
    }

    private var overallProgress: Double {
        guard !plan.topics.isEmpty else { return 0 }
        return plan.topics.reduce(0) { $0 + $1.progress } / Double(plan.topics.count)
    }
}

/// A thin progress ring: a faint track and an arc for how far along it is.
struct ReviewPlanRing: View {
    let progress: Double
    var tint: Color = .accentColor
    var lineWidth: CGFloat = 2

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .accessibilityHidden(true)
    }
}

struct ReviewPlanPopover: View {
    let plan: ChatReviewPlan
    let earlierTitles: [String]
    let onBackToPlan: () -> Void
    let onGoToTopic: (Int, String) -> Void
    let onClear: () -> Void

    /// Topics opened by hand; the active one is always open.
    @State private var opened: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)

            if plan.openQuestion != nil || plan.isOnDetour {
                whereYouAre
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }

            Divider().opacity(0.6)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(plan.topics.enumerated()), id: \.offset) { index, topic in
                        topicRow(index: index, topic: topic)
                    }
                    if !plan.parked.isEmpty || !earlierTitles.isEmpty {
                        footer
                            .padding(.top, 10)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
        }
        .frame(width: 360)
        .frame(maxHeight: 520)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(plan.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Menu {
                    Button("Clear Plan", role: .destructive, action: onClear)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 18)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.hoverWash(inset: -3))
                .fixedSize()
                .help("More")
            }
            segmentBar
            Text(summaryLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    /// One segment per topic, filled as far as its points have got.
    private var segmentBar: some View {
        HStack(spacing: 3) {
            ForEach(Array(plan.topics.enumerated()), id: \.offset) { _, topic in
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.1))
                        Capsule()
                            .fill(topic.status == .active ? Color.accentColor : Color.primary.opacity(0.45))
                            .frame(width: proxy.size.width * topic.progress)
                    }
                }
                .frame(height: 4)
            }
        }
        .accessibilityHidden(true)
    }

    private var summaryLine: String {
        var parts = [plan.progressLabel]
        if plan.totalPoints > 0 {
            parts.append("\(plan.donePoints) of \(plan.totalPoints) points")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Where the chat is

    private var whereYouAre: some View {
        VStack(alignment: .leading, spacing: 8) {
            if plan.isOnDetour {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .foregroundStyle(.orange)
                    Text(detourPath)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
            }
            if let question = plan.openQuestion {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Waiting for your answer")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(question)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if plan.isOnDetour {
                Button(action: onBackToPlan) {
                    Label("Back to plan", systemImage: "arrow.uturn.backward")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.hoverWash(in: Capsule(), inset: 0))
                .help("Leave the detours and take up the open question")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var detourPath: String {
        var stack: [String] = []
        if let index = plan.activeTopicIndex { stack.append(plan.topics[index].displayTitle) }
        return (stack + plan.detours).joined(separator: " › ")
    }

    // MARK: Topics

    private func isOpen(_ index: Int, _ topic: ChatReviewPlan.Topic) -> Bool {
        !topic.points.isEmpty && (topic.status == .active || opened.contains(index))
    }

    private func topicRow(index: Int, topic: ChatReviewPlan.Topic) -> some View {
        let open = isOpen(index, topic)
        return VStack(alignment: .leading, spacing: 0) {
            ReviewPlanTopicHeader(
                number: index + 1,
                topic: topic,
                isOpen: open,
                onToggle: {
                    guard topic.status != .active, !topic.points.isEmpty else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        if opened.contains(index) { opened.remove(index) } else { opened.insert(index) }
                    }
                },
                onGo: topic.status == .active ? nil : { onGoToTopic(index, topic.displayTitle) }
            )
            if open {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(topic.points.enumerated()), id: \.offset) { _, point in
                        pointRow(point)
                    }
                }
                .padding(.leading, 40)
                .padding(.trailing, 10)
                .padding(.top, 2)
                .padding(.bottom, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(topic.status == .active ? Color.accentColor.opacity(0.08) : .clear)
        )
    }

    private func pointRow(_ point: ChatReviewPlan.Point) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                switch point.status {
                case .done:
                    Image(systemName: "checkmark").foregroundStyle(.secondary)
                case .partial:
                    Image(systemName: "circle.lefthalf.filled").foregroundStyle(.secondary)
                default:
                    Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 9, weight: .semibold))
            .frame(width: 10)
            .accessibilityHidden(true)
            Text(point.text)
                .font(.callout)
                .foregroundStyle(point.status == .done ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(point.text), \(point.status == .done ? "done" : point.status == .partial ? "partly done" : "not yet")")
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !plan.parked.isEmpty {
                Text("Parked")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(plan.parked, id: \.self) { item in
                        Text(item)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                }
            }
            if !earlierTitles.isEmpty {
                Text("Earlier plans: \(earlierTitles.joined(separator: " · "))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, plan.parked.isEmpty ? 0 : 4)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }
}

/// A topic's line: its ring with the number, the title, its points count,
/// and on hover an arrow that asks the tutor to go there.
private struct ReviewPlanTopicHeader: View {
    let number: Int
    let topic: ChatReviewPlan.Topic
    let isOpen: Bool
    let onToggle: () -> Void
    let onGo: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            marker
                .frame(width: 20, height: 20)
            Text(topic.displayTitle)
                .font(.callout.weight(topic.status == .active ? .semibold : .regular))
                .foregroundStyle(topic.status == .todo ? .secondary : .primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            if let onGo, isHovering {
                Button(action: onGo) {
                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.hoverWash(in: Circle(), inset: -2))
                .help("Go to this topic")
            } else if !topic.points.isEmpty, topic.status != .done {
                Text("\(topic.donePoints)/\(topic.points.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .hoverHighlight(inset: 0, opacity: topic.status == .active ? 0 : 0.05)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var marker: some View {
        switch topic.status {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
        case .skipped:
            Image(systemName: "minus.circle")
                .font(.system(size: 17))
                .foregroundStyle(.tertiary)
        default:
            ZStack {
                ReviewPlanRing(
                    progress: topic.progress,
                    tint: topic.status == .active ? .accentColor : Color.primary.opacity(0.5),
                    lineWidth: 1.8
                )
                Text("\(number)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(topic.status == .active ? Color.accentColor : .secondary)
            }
        }
    }
}
