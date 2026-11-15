import SwiftUI

/// Today's cards, one at a time: the wording asked, a tap for the back, then
/// Forgot or Remembered (product owner, 2026-10-19: "i can't always type or
/// speak the answer"). The phone writes each grade as its own review would.
struct WatchCardsView: View {
    @EnvironmentObject private var store: WatchStore
    @State private var shownBackOf: String? = Self.openingBack

    var body: some View {
        Group {
            if let card = store.cardsLeft.first {
                cardView(card)
            } else {
                done
            }
        }
        .navigationTitle(title)
    }

    private static var openingBack: String? {
        #if DEBUG
        if WatchSample.revealsBack { return WatchStore.shared.cardsLeft.first?.itemID }
        #endif
        return nil
    }

    private var title: String {
        let left = store.cardsLeft.count
        return left == 0 ? "Cards" : "\(left) left"
    }

    @ViewBuilder
    private func cardView(_ card: WatchCard) -> some View {
        let isBackShown = shownBackOf == card.itemID
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let source = card.sourceTitle {
                    Text(source)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(card.prompt)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)

                if isBackShown {
                    Divider()
                    Text(card.back)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(card.why, id: \.self) { line in
                        Text(line)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // An icon over a small word, so both fit side by side on
                    // the smallest watch ("Remembered" broke mid-word as text).
                    HStack(spacing: 8) {
                        gradeButton("Forgot", symbol: "xmark", tint: .red) {
                            answer(card, remembered: false)
                        }
                        gradeButton("Remembered", symbol: "checkmark", tint: .green) {
                            answer(card, remembered: true)
                        }
                    }
                    .padding(.top, 4)
                } else {
                    Button("Show Answer") {
                        withAnimation { shownBackOf = card.itemID }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .id(card.itemID)
    }

    private func gradeButton(_ title: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.title3.weight(.semibold))
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity)
        }
        .tint(tint)
        .accessibilityLabel(title)
    }

    private var done: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text(store.hasHeardFromPhone ? "Done for today" : "Open ForeverLM on your iPhone to get today's cards.")
                .multilineTextAlignment(.center)
                .font(.footnote)
        }
    }

    private func answer(_ card: WatchCard, remembered: Bool) {
        store.grade(card, remembered: remembered)
        shownBackOf = nil
    }
}
