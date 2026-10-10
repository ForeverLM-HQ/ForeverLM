import SwiftUI

/// Settings › AI Usage › Spending: the daily cap on background AI, as a row
/// in the Spending card. Off unless the learner sets an amount; covers calls paid
/// by their own OpenRouter key as well as the balance.
/// `set_app_setting` `billing.background_daily_cap_usd` writes the same
/// preference.
struct BackgroundAIDailyCapRow: View {
    @State private var capUSD: Double? = BackgroundAIDailyCap.capUSD()
    @State private var spentTodayUSD: Double?

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(isReached ? "Daily background limit reached" : "Daily background limit")
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            TextField(
                "Off",
                value: $capUSD,
                format: .currency(code: "USD").precision(.fractionLength(2))
            )
            .multilineTextAlignment(.trailing)
            .frame(width: 96)
            .onSubmit { save() }
            .onChange(of: capUSD) { _, _ in save() }
        }
        .task { await loadSpentToday() }
        .onReceive(NotificationCenter.default.publisher(for: BackgroundAIDailyCap.didChange)) { _ in
            let stored = BackgroundAIDailyCap.capUSD()
            if stored != capUSD { capUSD = stored }
        }
    }

    private var isReached: Bool {
        guard let capUSD, let spentTodayUSD else { return false }
        return spentTodayUSD >= capUSD
    }

    private var detail: String {
        let spent = spentTodayUSD.map {
            $0.formatted(.currency(code: "USD").precision(.fractionLength(2)))
        } ?? "—"
        return "Clean-up, Listen preparation and other background work, own key included · \(spent) today"
    }

    private func save() {
        let current = BackgroundAIDailyCap.capUSD()
        let next = capUSD.flatMap { $0 > 0 ? min($0, BackgroundAIDailyCap.maximumUSD) : nil }
        guard current != next else { return }
        BackgroundAIDailyCap.setCapUSD(next)
        if capUSD != next { capUSD = next }
    }

    private func loadSpentToday() async {
        let day = BackgroundAIDailyCap.localDay(containing: Date())
        spentTodayUSD = try? await StorageService().backgroundAISpendUSD(from: day.start, to: day.end)
    }
}
