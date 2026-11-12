#if os(macOS)
import SwiftUI

// MARK: - A source's Linked References in the Reader
//
// docs/notes-graph-design.md, "A source's Linked References". A trailing
// panel beside the source, as Levels is, listing every block of every Doc in
// the source's library that cites it or stands on it, grouped by Doc (daily
// notes by their day), each block under its breadcrumbs, and the Ideas linked
// to the source. A click on a block opens its Doc at that block beside the
// Reader; a Doc's title opens the Doc; an Idea opens in the Ideas pane.
// Reading the graph writes nothing. The panel is opened from the Reader's ⋯
// menu (`ReaderReferencesMenuItem`), beside the Linked in submenu, which
// stays as it was: that names whole records, this shows the passages.
//
// One of the two at a time: Levels and Linked References are both the source
// seen from outside its text, each a column of the same width, and both open
// would leave the page a strip. Opening one hides the other
// (`ReaderReferencesPanelState`, `ReaderLevelsPanelState`). The Highlights
// list is the learner's own marks on the page and still stands beside either.

/// Whether the Reader's Linked References panel shows: this session's
/// choice in one window, like the Levels panel's.
@MainActor
@Observable
final class ReaderReferencesPanelState {
    /// The window's panels this one shares a column with.
    @ObservationIgnored weak var panels: ReaderSidePanels?

    var isVisible = false {
        didSet {
            // Levels, Linked References and Figure Legends share the trailing column.
            guard isVisible else { return }
            if panels?.levels.isVisible == true { panels?.levels.isVisible = false }
            if panels?.figureLegends.isVisible == true { panels?.figureLegends.isVisible = false }
        }
    }

    nonisolated init() {}
}

// MARK: - The panel

struct ReaderReferencesPanel: View {
    let article: StudioArticle

    @Environment(StudioViewModel.self) private var vm
    /// The Studio window it is in; nil in a pop-out Source Reader window,
    /// whose clicks open in the Studio window the learner was last in.
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?
    @Environment(\.uiZoomScale) private var uiZoomScale

    enum Phase: Equatable {
        case loading
        case ready
        case unreadable(String)
    }

    @State private var phase: Phase = .loading
    @State private var groups: [DocGraphReferenceGroup] = []
    /// The source the list on screen is for: a reload for the same source
    /// keeps it up while the new one is read.
    @State private var listedSourceID: String?
    /// Bumped when an Idea or anything an assistant wrote changes, so the
    /// list is read again.
    @State private var refreshToken = 0

    let state: ReaderReferencesPanelState

    /// What the list depends on: the source, its library, the Docs as they
    /// last saved (a Doc's save reloads the library's list), and the Ideas.
    private var loadKey: String {
        let newestDoc = vm.artifacts.lazy.map(\.updatedAt.timeIntervalSinceReferenceDate).max()
        return "\(article.id)|\(article.teamID ?? "")|\(newestDoc.map { String($0) } ?? "")|\(refreshToken)"
    }

    /// Blocks, and each linked Idea as one: what "N" counts in the header.
    private var referenceCount: Int {
        groups.reduce(0) { $0 + ($1.kind == .idea ? 1 : $1.blocks.count) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 320 * uiZoomScale)
        .frame(maxHeight: .infinity)
        .background(.background.secondary)
        .task(id: loadKey) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .ideasDidChange)) { _ in refreshToken &+= 1 }
        .onReceive(NotificationCenter.default.publisher(for: .foreverLMDataDidChange)) { _ in refreshToken &+= 1 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Linked References")
    }

    private func load() async {
        let sourceID = article.id
        let teamID = article.teamID
        if listedSourceID == sourceID {
            // A Doc saving as the learner types asks again on every save:
            // read once the typing pauses. A newer ask cancels this one.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
        } else {
            phase = .loading
            groups = []
        }
        do {
            let loaded = try await vm.storage.docGraphLinkedReferences(to: .source(sourceID), teamID: teamID)
            guard !Task.isCancelled else { return }
            groups = loaded
            phase = .ready
        } catch {
            guard !Task.isCancelled else { return }
            groups = []
            phase = .unreadable(error.localizedDescription)
        }
        listedSourceID = sourceID
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("Linked References")
                .font(.subheadline.weight(.semibold))
                .textSelection(.disabled)
            if phase == .ready, referenceCount > 0 {
                Text("\(referenceCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .textSelection(.disabled)
            }
            Spacer()
            Button {
                state.isVisible = false
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash)
            .help("Hide Linked References")
            .accessibilityLabel("Hide Linked References")
            .accessibilityIdentifier("reader.references.close")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unreadable(let message):
            ReaderPanelMessage(text: message)
        case .ready:
            if groups.isEmpty {
                ReaderPanelMessage(text: "Nothing links this source yet")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(groups, id: \.rowID) { group in
                            groupView(group)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private func groupView(_ group: DocGraphReferenceGroup) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                open(group, at: nil)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: Self.symbolName(for: group.kind))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    Text(group.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: 0.07))
            .help(group.kind == .idea ? "Open this idea" : "Open \u{201C}\(group.title)\u{201D}")
            .contextMenu {
                if group.kind != .idea { OtherWindowMenuItem(.doc(group.id)) }
            }
            .accessibilityIdentifier("reader.references.page")

            ForEach(Array(group.blocks.enumerated()), id: \.offset) { _, block in
                blockRow(block, in: group)
            }
        }
    }

    private func blockRow(_ block: DocGraphBlock, in group: DocGraphReferenceGroup) -> some View {
        Button {
            open(group, at: block)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                if !block.breadcrumbs.isEmpty {
                    Text(block.breadcrumbs.joined(separator: " \u{203A} "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Text(block.plainText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .padding(.leading, 28)
            .padding(.trailing, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: 0.07))
        .help("Open \u{201C}\(group.title)\u{201D} at this passage")
        .contextMenu { OtherWindowMenuItem(.doc(group.id)) }
        .accessibilityLabel(block.plainText)
        .accessibilityIdentifier("reader.references.block")
    }

    // MARK: Opening

    /// A Doc opens beside the Reader, at the block when one was clicked, so
    /// the source stays where the learner is reading it; an Idea opens in
    /// the Ideas pane.
    private func open(_ group: DocGraphReferenceGroup, at block: DocGraphBlock?) {
        let window = windowState
        Task { @MainActor in
            switch group.kind {
            case .idea:
                await vm.openIdea(group.id)
            case .doc, .dailyNote:
                if let window { vm.revealCenterTab(.notepad, beside: .reader, in: window) }
                await vm.openDoc(
                    group.id,
                    revealing: block.map { DocBlockReveal(blockID: $0.blockID, key: $0.key, plainText: $0.plainText) },
                    in: window
                )
            }
        }
    }

    static func symbolName(for kind: DocGraphReferenceGroup.Kind) -> String {
        switch kind {
        case .doc: return "doc.text"
        case .dailyNote: return "calendar"
        case .idea: return "lightbulb"
        }
    }
}

private extension DocGraphReferenceGroup {
    /// A Doc and an Idea never share an id, but the list does not rely on it.
    var rowID: String { "\(kind.rawValue):\(id)" }
}

// MARK: - The ⋯ menu's item

/// **Linked References** in the Reader's ⋯ menu: shows or hides the panel.
/// Offered for every saved source; a live page reached through a link is
/// not one, and its Reader leaves the item out.
struct ReaderReferencesMenuItem: View {
    let state: ReaderReferencesPanelState

    var body: some View {
        Button {
            state.isVisible.toggle()
        } label: {
            Label(state.isVisible ? "Hide Linked References" : "Linked References", systemImage: "arrow.turn.up.left")
        }
        .help("Every passage of your Pages that cites this source, and the Ideas linked to it")
    }
}
#endif

/// A quiet message centred in a reader side panel: nothing to show, or why.
struct ReaderPanelMessage: View {
    let text: String

    var body: some View {
        VStack {
            Spacer()
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.disabled)
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
