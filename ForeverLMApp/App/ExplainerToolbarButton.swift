#if os(macOS)
import SwiftUI

/// The Reader toolbar's Explain control, shown only while the source's
/// explainer is being written (Quiet chrome, docs/ui-design.md, 2026-10-06):
/// the spinner and, beside it, the same small cancel Listen shows while its
/// audio is generating. Writing and opening the explainer are the ⋯ menu's
/// (`ExplainerMenuItems`).
struct ExplainerToolbarButton: View {
    let article: StudioArticle

    @Environment(\.uiZoomScale) private var uiZoomScale
    @ObservedObject private var coordinator = ExplainerGenerationCoordinator.shared

    var body: some View {
        if coordinator.isWriting(article.id) {
            HStack(spacing: 2) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 14, height: 14)
                    .help("Writing the explainer…")
                    .accessibilityIdentifier("reader.explainer.writing")
                ReaderToolbarButton(
                    help: "Cancel writing the explainer",
                    accessibilityLabel: "Cancel explainer",
                    accessibilityIdentifier: "reader.explainer.cancel",
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

/// The explainer's menu items: **Open Explainer** when the source has one,
/// then **Generate Explainer** / **Rewrite Explainer**, or **Cancel Writing
/// Explainer** while a write is in flight. The sidebar's context menu and the
/// reader's ⋯ menu both offer them; the ⋯ is the Reader's only way to
/// them (Quiet chrome), the toolbar having no lightbulb.
///
/// Nothing here without `GeneratedExplainer.canExplain(article)`: a paper
/// still being ingested, or an explainer itself, offers no explainer.
struct ExplainerMenuItems: View {
    let article: StudioArticle
    /// The window whose Reader opens the explainer; nil means the key window.
    var windowState: StudioWindowState? = nil

    @Environment(StudioViewModel.self) private var vm
    @ObservedObject private var coordinator = ExplainerGenerationCoordinator.shared

    var body: some View {
        if GeneratedExplainer.canExplain(article) {
            // The explainer has no row of its own in the sidebar, so the
            // source's menu is where it opens; the source's row stays selected.
            let existingExplainer = vm.explainer(explaining: article.id)
            if let existingExplainer {
                Button {
                    (windowState ?? vm.activeWindowState).sidebarSelectedSourceIDs = [article.id]
                    Task { await vm.selectArticle(existingExplainer.id, in: windowState, revealingReader: true) }
                } label: {
                    Label("Open Explainer", systemImage: "lightbulb.fill")
                }
                .help("Read this source's explainer")
            }
            if coordinator.isWriting(article.id) {
                // The write in flight; stopping it saves nothing, and a
                // source that already had an explainer keeps it.
                Button {
                    coordinator.cancel(article.id)
                } label: {
                    Label("Cancel Writing Explainer", systemImage: "xmark.circle")
                }
                .help("Stop writing this source's explainer; nothing is saved")
            } else {
                // Writes the explainer (or rewrites the one the source has),
                // opens it, and offers its audio the way Generate Audio does.
                Button {
                    let article = article
                    Task { await coordinator.explain(article, in: vm) }
                } label: {
                    Label(
                        existingExplainer == nil ? "Generate Explainer" : "Rewrite Explainer",
                        systemImage: "lightbulb"
                    )
                }
                .help(
                    existingExplainer == nil
                        ? "Write a spoken explainer of this source and narrate it"
                        : "Write this source's explainer again, replacing the one it has"
                )
            }
        }
    }
}
/// **Linked in**: the artifacts a source is linked to — a Doc grounded on it
/// or citing it, a site whose cards name it, an animation about it — each
/// row opening that artifact. Shared by the sidebar row's context menu and
/// the reader's ⋯ menu; absent when nothing links to the source. The list is
/// resolved when the menu opens, on the storage actor, never in a view body
/// (docs/docs-design.md, "Linked in"; the product owner, 2026-09-18).
struct LinkedInMenuItems: View {
    let article: StudioArticle
    /// The window the artifact opens in; nil means the key window.
    var windowState: StudioWindowState? = nil

    @Environment(StudioViewModel.self) private var vm
    @State private var links: [StorageService.SourceArtifactLink] = []

    var body: some View {
        Group {
            if !links.isEmpty {
                Menu {
                    ForEach(links, id: \.artifact.id) { link in
                        Button {
                            vm.revealArtifact(link.artifact.id, in: windowState)
                        } label: {
                            Label(link.artifact.title, systemImage: Self.symbolName(for: link.artifact))
                        }
                    }
                } label: {
                    Label("Linked in (\(links.count))", systemImage: "link")
                }
            }
        }
        .task(id: article.id) {
            links = await vm.linkedArtifacts(forSource: article.id)
        }
    }

    /// The kind's mark: an animation's, a page's globe, a Doc's page.
    static func symbolName(for artifact: ArtifactRecord) -> String {
        if artifact.isAnimation { return ArtifactKind.animation.symbolName }
        if artifact.isLinked { return "globe" }
        return "doc.text"
    }
}

#endif
