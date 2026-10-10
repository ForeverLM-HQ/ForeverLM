#if os(macOS)
import SwiftUI

/// The Reader toolbar's Cards control, shown only while it has something to
/// say (Quiet chrome, docs/ui-design.md, 2026-10-06). While cards drafted
/// from the source wait to be gone through it reads "Cards · N to check" and
/// opens them in To Check beside the Reader; while the source's cards are
/// being drafted it shows the spinner and a Stop. Otherwise it draws nothing:
/// Make Cards is the ⋯ menu's (`CardsMenuItems`), which also carries the
/// same To Check and Stop. On a narrow bar the count stands alone ("6").
struct CardsToolbarButton: View {
    let article: StudioArticle
    /// "Cards · 6 to check", or just the count beside the glyph.
    var showsTitle = true

    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    @Environment(\.uiZoomScale) private var uiZoomScale
    @ObservedObject private var coordinator = CardDraftingCoordinator.shared

    var body: some View {
        let toCheck = vm.memoryCardsToCheck(sourceID: article.id)
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
        } else if toCheck > 0 {
            let title = showsTitle ? Self.toCheckTitle(toCheck) : "\(toCheck)"
            ReaderToolbarButton(
                help: "Go through the cards drafted from this source",
                accessibilityLabel: "Cards, \(toCheck) to check",
                accessibilityIdentifier: "reader.cards.toCheck",
                controlSize: 26 * uiZoomScale,
                controlWidth: Self.labelWidth(title) * uiZoomScale,
                action: openToCheck
            ) {
                HStack(spacing: 5) {
                    Image(systemName: MemoryReviewSession.sidebarIcon)
                    Text(title)
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .textSelection(.disabled)
            }
        }
    }

    /// "Cards · 3 to check"
    static func toCheckTitle(_ count: Int) -> String {
        "Cards · \(count) to check"
    }

    /// Room for the glyph and the words, at the caption size.
    static func labelWidth(_ title: String) -> CGFloat {
        CGFloat(22 + title.count * 6)
    }

    private func openToCheck() {
        vm.openCardsToCheckBesideReader(sourceID: article.id, in: windowState)
    }
}

/// The source's card items, for the Reader's ⋯ menu and the sidebar's
/// context menu: **Make Cards…**, **Cards to Check (N)** while drafts wait,
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
                    vm.presentReaderMakeCards(sourceID: article.id, in: windowState)
                } label: {
                    Label("Make Cards…", systemImage: MemoryReviewSession.sidebarIcon)
                }
                .help("Draft cards from this source for Memory's To Check")
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
