#if os(macOS)
import SwiftUI

/// What Make Cards opens first — the Reader's for its source, the notebook's
/// Studio Cards tile for its ticked sources — and the second press that
/// drafts (docs/memory-design.md, "Drafting"): how many cards (Auto, about
/// four a source and at most forty, or 10, 20, 40), a focus, the sources
/// line ("15 sources · 11 not opened here", naming those left out and those
/// too long to read whole, which are sampled), and the price with the model.
/// Make closes the sheet; the cards arrive kept by default in Memory's To
/// Check, which opens beside the Reader once they are ready.
///
/// Presented by `makeCardsSheet()` on the Studio window, for the target
/// `StudioViewModel.presentMakeCards(notebookID:sourceIDs:)` set.
struct MakeCardsSheet: View {
    var vm: StudioViewModel
    let target: MakeCardsTarget
    @Environment(\.dismiss) private var dismiss

    @State private var count: MemoryCardRequestCount = .auto
    @State private var focus = ""
    @State private var materials: CardDraftingMaterials?
    @State private var plan: CardDraftingPlan?
    @State private var errorMessage: String?
    @State private var isLoading = true

    private var trimmedFocus: String? {
        let text = focus.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The plan for what is on screen, and only that: while a change is
    /// being re-planned, Make waits rather than make what the previous price
    /// described.
    private var currentPlan: CardDraftingPlan? {
        guard let plan, plan.request.count == count,
              plan.request.focus == trimmedFocus.map(FlashcardDeck.singleLine) else { return nil }
        return plan
    }

    private var canMake: Bool {
        guard let plan = currentPlan else { return false }
        return plan.cardCount > 0
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text("Make Cards").font(.headline)
                Spacer()
                Button("Make") { make() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canMake)
                    .accessibilityIdentifier("make-cards.make")
            }
            .padding()

            Divider()

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("Cards")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Picker("Cards", selection: $count) {
                        ForEach(MemoryCardRequestCount.choices) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("make-cards.count")
                }
                GridRow {
                    Text("Focus").foregroundStyle(.secondary)
                    TextField("Focus", text: $focus, prompt: Text("Optional"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(maxWidth: 320)
                        .accessibilityIdentifier("make-cards.focus")
                }
                GridRow {
                    Text("Sources").foregroundStyle(.secondary)
                    sourcesLine
                }
                GridRow {
                    Text("Price").foregroundStyle(.secondary)
                    priceLine
                }
            }
            .padding(20)

            if isLoading || errorMessage != nil {
                Divider()
                statusRow
            }
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .task { await load() }
        .onChange(of: count) { _, _ in
            Task { await replan() }
        }
        .onChange(of: focus) { _, _ in
            Task { await replan() }
        }
    }

    // MARK: Lines

    @ViewBuilder
    private var sourcesLine: some View {
        if let materials {
            VStack(alignment: .leading, spacing: 3) {
                Text(StudioViewModel.makeCardsSourcesLine(
                    sourceCount: materials.sources.count,
                    notOpened: materials.sources.filter { !$0.isOpened }.count
                ))
                if let detail = Self.detail(plan, skipped: materials.skipped) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
            }
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var priceLine: some View {
        if let plan = currentPlan {
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.priceLine(cardCount: plan.cardCount, isFree: plan.callCount == 0, cost: plan.cost.label))
                Text(plan.callCount == 0 ? "No model call: the walkthroughs' own questions" : plan.route.writing.modelLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    /// The price line, with how many cards it buys — what Auto comes to over
    /// these sources: "24 cards · $0.04", "10 cards · free".
    static func priceLine(cardCount: Int, isFree: Bool, cost: String) -> String {
        let cards = cardCount == 1 ? "1 card" : "\(cardCount) cards"
        return "\(cards) · \(isFree ? "free" : cost)"
    }

    /// The sources left out and those read as excerpts, by name: the sheet
    /// says what the cards are drafted from.
    static func detail(_ plan: CardDraftingPlan?, skipped: [CardDraftingSkip]) -> String? {
        var parts: [String] = []
        let leftOut = plan?.skipped ?? skipped
        if !leftOut.isEmpty {
            parts.append("Left out: " + leftOut.map { "\($0.title) (\(Self.clause($0.reason)))" }
                .joined(separator: "; ") + ".")
        }
        if let sampled = plan?.sampledTitles, !sampled.isEmpty {
            parts.append("Too long for the model's window, so read as excerpts: \(sampled.joined(separator: "; ")).")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// A reason as a clause inside parentheses: its first letter lower case
    /// (names such as AI and ForeverLM keep theirs), without its full stop.
    static func clause(_ reason: String) -> String {
        var text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") { text.removeLast() }
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 10) {
            if let errorMessage {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            } else {
                ProgressView().controlSize(.small)
                Text("Reading the sources")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .textSelection(.disabled)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: Actions

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let request = CardDraftingRequest(
            notebookID: target.notebookID,
            sourceIDs: target.sourceIDs,
            count: count,
            focus: trimmedFocus,
            trigger: .requested
        )
        do {
            materials = try await CardDraftingCoordinator.load(request, storage: vm.storage)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        await replan()
    }

    private func replan() async {
        guard let materials else { return }
        let asked = (count, trimmedFocus)
        do {
            let planned = try await CardDraftingCoordinator.plan(materials, count: asked.0, focus: asked.1)
            // A slower answer for options the learner has since changed is not theirs.
            guard planned.request.count == count, asked.1 == trimmedFocus else { return }
            plan = planned
            errorMessage = planned.cardCount == 0 ? CardDraftingError.noSources.localizedDescription : nil
        } catch {
            guard asked.0 == count, asked.1 == trimmedFocus else { return }
            plan = nil
            errorMessage = error.localizedDescription
        }
    }

    private func make() {
        guard canMake, let plan = currentPlan else { return }
        dismiss()
        let vm = vm
        let windowID = target.windowID
        Task {
            await vm.makeCards(plan, windowID: windowID)
        }
    }
}
#endif
