#if os(macOS)
import SwiftUI

/// The Reader toolbar's Cards control, shown only while the source's cards
/// are being drafted: the spinner and a Stop (Quiet chrome, docs/ui-design.md).
/// Cards waiting to be gone through stay off the bar (product owner,
/// 2026-10-12, of the glyph and its count over a paper: "not sure i like this
/// brain icon in the top bar of a source i'm reading … app should be super
/// clean like the chatgpt app"); they wait in To Check, and the ⋯ menu's
/// Write Card (`CardsMenuItems`) writes one.
struct CardsToolbarButton: View {
    let article: StudioArticle

    @Environment(\.uiZoomScale) private var uiZoomScale
    @ObservedObject private var coordinator = CardDraftingCoordinator.shared

    var body: some View {
        if let run = coordinator.run(drafting: article.id) {
            HStack(spacing: 2) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 14, height: 14)
                    .help(run.progress.label)
                    .accessibilityIdentifier("reader.cards.drafting")
                ReaderToolbarButton(
                    help: "Stop making cards",
                    accessibilityLabel: "Stop making cards",
                    accessibilityIdentifier: "reader.cards.stop",
                    controlSize: 22 * uiZoomScale,
                    washInset: 3,
                    action: { coordinator.cancel(run.id) }
                ) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The source's card item, for the Reader's ⋯ menu: **Write Card**, or
/// **Stop Making Cards** while they are being drafted. Drafts waiting to be
/// checked are reached from To Check, not from here (the ⋯ was cut down,
/// 2026-11-24).
struct CardsMenuItems: View {
    let article: StudioArticle
    let windowState: StudioWindowState

    @Environment(StudioViewModel.self) private var vm
    @ObservedObject private var coordinator = CardDraftingCoordinator.shared

    var body: some View {
        if CardsToolbarButton.canMakeCards(from: article) {
            if let run = coordinator.run(drafting: article.id) {
                Button {
                    coordinator.cancel(run.id)
                } label: {
                    Label("Stop Making Cards", systemImage: "stop.circle")
                }
            } else {
                Button {
                    vm.requestReaderWriteCard(sourceID: article.id, in: windowState)
                } label: {
                    Label("Write Card", systemImage: MemoryReviewSession.sidebarIcon)
                }
                .help("Write this source's card beside it")
            }
        }
    }
}

extension CardsToolbarButton {
    /// Whether cards can be drafted from a source: any saved source with
    /// text, but a spoken script ForeverLM wrote (an explainer's or an audio
    /// overview's, which retell their sources).
    static func canMakeCards(from article: StudioArticle) -> Bool {
        !TextToSpeechPreparationPolicy.isSpokenScript(url: article.url)
    }
}
#endif
