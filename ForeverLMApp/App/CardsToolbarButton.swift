#if os(macOS)
import SwiftUI

/// The Reader toolbar's Cards control, shown only while the source's cards
/// are being drafted: the spinner and a Stop (Quiet chrome, docs/ui-design.md).
/// Cards waiting to be gone through stay off the bar (product owner,
/// 2026-10-12, of the glyph and its count over a paper: "not sure i like this
/// brain icon in the top bar of a source i'm reading … app should be super
/// clean like the chatgpt app"); the ⋯ menu's **Cards to Check (N)**
/// (`CardsMenuItems`) opens them, and Make Cards is there too.
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

/// The source's card items, for the Reader's ⋯ menu and the sidebar's
/// context menu: **Write Card**, **Cards to Check (N)** while drafts wait,
/// and **Stop Making Cards** while they are being drafted.
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
            let toCheck = vm.memoryCardsToCheck(sourceID: article.id)
            if toCheck > 0 {
                Button {
                    vm.openCardsToCheckBesideReader(sourceID: article.id, in: windowState)
                } label: {
                    Label("Cards to Check (\(toCheck))", systemImage: "checklist")
                }
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
