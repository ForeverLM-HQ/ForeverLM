import SwiftUI

/// The offer to have today's review ready each morning, shown under the
/// "Planning today's review" status line once the wait has run a few seconds.
///
/// One quiet action, no question. The learner clicked Memory for a review, not
/// to be asked something, so the row states what could be different and offers
/// the one thing that does it; there is nothing to decline. It is shown on at
/// most `DailyReviewPreparation.maxOfferShowings` planning waits and then goes
/// away on its own — being let pass a few times is the answer. Taking it, or
/// touching the switch in Settings → Memory, retires it at once. Taken, the row
/// confirms what will happen and where to change it, for the rest of the turn.
struct MemoryReviewPreparationOffer: View {
    /// Whether the turn is in its planning phase. The offer is only shown then;
    /// the confirmation stays up while the tutor writes the opener.
    let isPlanning: Bool
    /// When the turn began, so the offer appears `offerDelay` seconds into the
    /// wait rather than the instant planning starts.
    let startedAt: Date

    /// Whether the offer stands, read once when the turn's view is created so
    /// recording this showing cannot retire it mid-wait.
    @State private var stands = DailyReviewPreparation.shouldOffer
    @State private var recorded = false
    @State private var accepted = false

    private var hourLabel: String {
        DailyReviewPreparation.hourLabel(DailyReviewPreparation.defaultHour)
    }

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            if accepted {
                confirmation
            } else if stands, isPlanning,
                      context.date.timeIntervalSince(startedAt) >= DailyReviewPreparation.offerDelay {
                offer
                    .onAppear(perform: recordShowing)
            }
        }
    }

    private var offer: some View {
        HStack(spacing: 6) {
            Text("This planning can happen before you sit down.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                accept()
            } label: {
                Text("Have it ready by \(hourLabel) each morning")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .help("Plan today's review at \(hourLabel) each morning on a Mac that is open, with its first question waiting. One planning call and one opening message a day, billed to your OpenRouter key. Settings › General changes the hour or turns it off.")
            .accessibilityIdentifier("mac.chatMemoryPrepareOffer.accept")

            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .padding(.leading, ForeverLMLoadingIndicator.inlineWidth + 8)
        .padding(.top, 2)
        .transition(.opacity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Offer to prepare the daily review ahead of time")
    }

    private var confirmation: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Ready by \(hourLabel) each morning from now on. Settings › General changes the hour.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.leading, ForeverLMLoadingIndicator.inlineWidth + 8)
        .padding(.top, 2)
        .transition(.opacity)
        .accessibilityIdentifier("mac.chatMemoryPrepareOffer.confirmation")
    }

    private func recordShowing() {
        guard !recorded else { return }
        recorded = true
        DailyReviewPreparation.recordOfferShown()
    }

    private func accept() {
        withAnimation(.easeInOut(duration: 0.2)) {
            accepted = true
        }
        DailyReviewPreparation.setEnabled(true)
        DailyReviewPreparation.hour = DailyReviewPreparation.defaultHour
        DailyReviewPreparation.markOfferDecided()
        Task {
            _ = await CohortReviewNotifications.requestAuthorization()
            // Scheduled only while the next morning holds a card.
            await MemoryReviewPreparationRunner.shared.refreshReminder()
        }
        MemoryReviewPreparationRunner.shared.scheduleRefresh()
    }
}
