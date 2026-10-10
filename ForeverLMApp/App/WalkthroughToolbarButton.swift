#if os(macOS)
import SwiftUI

/// The Reader toolbar's Walk Through control, shown only while the source's
/// walkthrough is being written (Quiet chrome, docs/ui-design.md,
/// 2026-10-06): the spinner, its stage as help, and a small cancel. Writing
/// and playing the walk are the ⋯ menu's (`WalkthroughMenuItems`); the chat
/// beside the Reader plays a new walk as soon as its steps are saved
/// (walkthrough-design.md, "the panel becomes a chat").
struct WalkthroughToolbarButton: View {
    let article: StudioArticle

    @Environment(\.uiZoomScale) private var uiZoomScale
    @ObservedObject private var coordinator = WalkthroughGenerationCoordinator.shared

    var body: some View {
        if coordinator.isGenerating(article.id) {
            HStack(spacing: 2) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 14, height: 14)
                    .help(coordinator.stage(for: article.id)?.label ?? "Writing the walkthrough…")
                    .accessibilityIdentifier("reader.walkthrough.writing")
                ReaderToolbarButton(
                    help: "Cancel writing the walkthrough",
                    accessibilityLabel: "Cancel walkthrough",
                    accessibilityIdentifier: "reader.walkthrough.cancel",
                    controlSize: 22 * uiZoomScale,
                    washInset: 3,
                    action: { coordinator.cancel(article.id) }
                ) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The walkthrough's menu items, for the reader's ⋯ menu and the sidebar's
/// context menu: **Walk Through Paper** (Chapter, Article), then **Write
/// Walkthrough** / **Write Walkthrough Again**, or
/// **Cancel Writing Walkthrough** while a run is in flight, and **Remove
/// Walkthrough** when there is one. Nothing here without a source whose text
/// is there to walk through (`PaperWalkthroughSubject.isReady`).
struct WalkthroughMenuItems: View {
    let article: StudioArticle
    /// Whether the source has a walk, when the host already knows. The
    /// Reader's ⋯ is an `NSHostingMenu` built at each press, where this
    /// view's own lookup never lands: on 2026-09-21 it offered Write
    /// Walkthrough but not Walk Through Paper for a paper with a walk. Nil
    /// looks it up, as the sidebar's context menu does.
    var knownHasWalkthrough: Bool? = nil

    @Environment(StudioViewModel.self) private var vm
    @ObservedObject private var coordinator = WalkthroughGenerationCoordinator.shared
    @State private var lookedUpHasWalkthrough = false

    private var hasWalkthrough: Bool { knownHasWalkthrough ?? lookedUpHasWalkthrough }

    private var subject: PaperWalkthroughSubject? { PaperWalkthroughSubject.of(article) }
    private var noun: String { subject?.noun ?? "source" }

    /// What the writer points at, for the Write item's help: figures for a
    /// source shown as a PDF, passages for one shown as text.
    private var writeHelp: String {
        PaperWalkthroughSubject.allowsFigureAnchors(article)
            ? "Write a step-by-step walkthrough of this \(noun)'s figures and key passages, with questions and animations"
            : "Write a step-by-step walkthrough of this \(noun)'s key passages, with questions and animations"
    }

    var body: some View {
        if PaperWalkthroughGeneratorService.canPlayWalkthrough(article) {
            Group {
                if hasWalkthrough {
                    Button {
                        vm.requestWalkthroughPlayback(for: article.id)
                    } label: {
                        Label("Walk Through \(noun.capitalized)", systemImage: "figure.walk")
                    }
                    .help("Walk through the \(noun), a card at a time, beside it")
                }
                // A video's walk is an assistant's to write: only playing and
                // removing it are offered for one.
                if subject?.writerWrites == true {
                    if coordinator.isGenerating(article.id) {
                        Button {
                            coordinator.cancel(article.id)
                        } label: {
                            Label("Cancel Writing Walkthrough", systemImage: "xmark.circle")
                        }
                        .help("Stop writing; the steps saved so far stay")
                    } else {
                        Button {
                            let article = article
                            Task { await coordinator.generate(article, in: vm) }
                        } label: {
                            Label(
                                hasWalkthrough ? "Write Walkthrough Again" : "Write Walkthrough",
                                systemImage: "figure.walk.motion"
                            )
                        }
                        .help(
                            hasWalkthrough
                                ? "Write this \(noun)'s walkthrough again, replacing the one it has"
                                : writeHelp
                        )
                    }
                }
                if hasWalkthrough, !coordinator.isGenerating(article.id) {
                    Button {
                        let article = article
                        Task { await coordinator.remove(article, in: vm) }
                    } label: {
                        Label("Remove Walkthrough", systemImage: "trash")
                    }
                }
            }
            .task(id: "\(article.id)#\(vm.readerWalkthroughRevision)") {
                guard knownHasWalkthrough == nil else { return }
                lookedUpHasWalkthrough = await WalkthroughGenerationCoordinator.hasWalkthrough(for: article, storage: vm.storage)
            }
        }
    }
}
#endif
