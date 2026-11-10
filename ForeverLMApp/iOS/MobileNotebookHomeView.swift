import SwiftUI

/// The glyph the phone draws for notebooks where no one notebook's emoji
/// fits (an empty Home, a header that takes a symbol): the Mac's notebook
/// glyph (`NotebookGlyph`, a bound book with writing on it; the Mac file is
/// macOS-only, so the name is repeated here). A notebook is neither a folder
/// nor a grid, which is Plugins'.
enum MobileNotebookGlyph {
    static let symbolName = "text.book.closed"
}

/// Home, drawn as ChatGPT's app draws its own (product owner, 2026-11-09:
/// "copy the design from the ChatGPT app", "essentially, be the same"): a
/// composer pill whose round button starts a call, three suggestion rows, and
/// a side drawer for every other place (`MobileHomeDashboard`). A running bout
/// sits at the top while there is one. Voice reaches the rest by itself: it
/// opens a source the learner names, and offers today's cards first.
struct MobileNotebookHomeView: View {
    /// Pushes a route on the shell's stack.
    let open: (MobileShellRoute) -> Void

    @EnvironmentObject private var vm: MobileAudioReviewViewModel
    /// The Planner's bout, when one is running on a Mac.
    @ObservedObject private var boutTimer = MobileLearningBoutTimer.shared
    /// The Space, whose menu item shows once the phone's pages can open here (generation 2).
    @Environment(MobileSpaceStore.self) private var spaceStore
    @ObservedObject private var railStore = MobileNotebookRailStore.shared

    /// The five notebooks worked in last, as the Notebooks screen's Recent
    /// order reads them, for the drawer's list under its rule.
    private var recents: [MobileHomeRecent] {
        let recency = MobileNotebookRailRules.recency(opened: railStore.opened, lastChatAt: vm.lastNotebookChatAt)
        return vm.notebooks
            .sorted {
                recency.lastWorkedAt($0.id, updatedAt: $0.updatedAt) > recency.lastWorkedAt($1.id, updatedAt: $1.updatedAt)
            }
            .prefix(5)
            .map { MobileHomeRecent(id: $0.id, title: NotebookTitle($0.title).text) }
    }

    var body: some View {
        MobileHomeDashboard(
            showsSpaces: spaceStore.isAvailable,
            recents: recents,
            actions: MobileHomeActions(
                open: open,
                talk: { Task { await MobileRealtimeVoice.startAssistant(setting: .phone) } },
                send: { text in
                    // The call is the chat: start the assistant, then ask what was typed.
                    Task {
                        await MobileRealtimeVoice.startAssistant(setting: .phone)
                        MobileRealtimeVoice.controller.ask(text)
                    }
                }
            )
        ) {
            if let bout = boutTimer.bout, bout.phase().isLive {
                MobileLearningBoutCard(timer: boutTimer)
            }
        }
        .task {
            if !spaceStore.isAvailable { await spaceStore.refresh() }
        }
    }
}

/// One chip in the Notebooks screen's filter row: its name in grey, and in
/// the primary colour on a neutral capsule while it is the filter, as the
/// Mac's chips are since 2026-10-06 ("Lists are monochrome",
/// docs/ui-design.md); it was filled with the accent and carried its count
/// of notebooks before.
struct MobileNotebookCollectionChip: View {
    static let height: CGFloat = 34
    /// Taps above and below the capsule still land on it: a 44-point target.
    static let verticalHitPadding: CGFloat = (MobileDesign.Metrics.minimumTouchTarget - height) / 2

    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .lineLimit(1)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .padding(.horizontal, MobileDesign.Spacing.medium)
                .frame(height: Self.height)
                .background(
                    isSelected ? Color(uiColor: .secondarySystemGroupedBackground) : Color.clear,
                    in: Capsule()
                )
                .padding(.vertical, Self.verticalHitPadding)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A gallery card's ▶ (or ⏸) for the notebook's audio overview, a spinner
/// while that audio is being made, as the Mac's card draws it
/// (`NotebookCardPlayButton`). A card with no overview draws nothing here:
/// the waveform that talked with the notebook went on 2026-10-06.
private struct MobileNotebookCardPlayButton: View {
    let overviewIsPlaying: Bool
    let isPreparingOverview: Bool
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            Group {
                if isPreparingOverview {
                    ProgressView()
                        .controlSize(.small)
                        .frame(
                            width: MobileDesign.Metrics.minimumTouchTarget,
                            height: MobileDesign.Metrics.minimumTouchTarget
                        )
                } else {
                    MobileCircularActionLabel(systemImage: overviewIsPlaying ? "pause.fill" : "play.fill")
                }
            }
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(overviewIsPlaying ? "Pause audio overview" : "Play audio overview")
        .accessibilityIdentifier("home.notebook.playOverview")
    }
}

extension NotebookTint {
    /// The notebook's tint as a colour that follows light and dark mode.
    static func color(for notebookID: String) -> Color {
        let index = index(for: notebookID)
        return Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark[index] : light[index]
            return UIColor(
                red: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

/// One notebook in Home's gallery on iPad, the Mac's `NotebookGalleryCard`,
/// drawn as NotebookLM draws its own: a card in the notebook's soft colour
/// (`NotebookTint`), its emoji large in the corner, its name under it and
/// "12 sources · 2 hr ago", and ▶ in its bottom-right corner while it has an
/// audio overview. The same data as the phone's row (`MobileNotebookCard`)
/// and the same menu; a tap opens the notebook. Since 2026-10-06, as the
/// Mac's card, it draws no pin (Pinned on Home and the menu's Unpin say it)
/// and no waveform. On a phone's Notebooks screen the
/// card is drawn smaller (`isCompact`), two to a row.
struct MobileNotebookGalleryCard: View {
    let notebook: MobileCloudNotebook
    let sourceCount: Int
    let lastActivity: Date
    let overviewIsPlaying: Bool
    let hasOverview: Bool
    let isPreparingOverview: Bool
    let onOpen: () -> Void
    let onPlay: () -> Void
    var isCompact = false

    /// "12 sources · 2 hr ago", "Sources syncing" while none of a notebook's
    /// sources has reached the phone, and "0 sources" for an empty one, as
    /// the Mac's card counts it (its "No sources yet" went on 2026-10-06).
    static func line(notebook: MobileCloudNotebook, sourceCount: Int, lastActivity: Date) -> String {
        let count: String
        if sourceCount == 0, !notebook.sourceIDs.isEmpty {
            count = "Sources syncing"
        } else {
            count = sourceCount == 1 ? "1 source" : "\(sourceCount) sources"
        }
        guard lastActivity > .distantPast else { return count }
        return "\(count) · \(lastActivity.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))"
    }

    /// The Mac card's corner.
    private static let cornerRadius: CGFloat = 16
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
    }

    var body: some View {
        let title = NotebookTitle(notebook.title)
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                MobileNotebookIconView(notebookID: notebook.id, size: isCompact ? 36 : 44, cornerRadius: 10) {
                    Text(title.displayIcon)
                        .font(.system(size: isCompact ? 28 : 34))
                }
                .accessibilityHidden(true)

                Spacer(minLength: MobileDesign.Spacing.medium)

                Text(title.text.isEmpty ? "Untitled notebook" : title.text)
                    .font(isCompact ? .subheadline.weight(.semibold) : .headline)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isCompact {
                    // The round button sits in the top-right corner, beside the
                    // emoji, so every card's name rests on its foot.
                    Text(MobileNotebookGalleryCard.line(notebook: notebook, sourceCount: sourceCount, lastActivity: lastActivity))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.top, 2)
                } else {
                    Text(MobileNotebookGalleryCard.line(notebook: notebook, sourceCount: sourceCount, lastActivity: lastActivity))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        // The round button sits in the bottom-right corner.
                        .padding(.trailing, hasOverview ? MobileDesign.Metrics.minimumTouchTarget + MobileDesign.Spacing.small : 0)
                        .frame(minHeight: MobileDesign.Metrics.minimumTouchTarget - MobileDesign.Spacing.small, alignment: .bottomLeading)
                }
            }
            .padding(isCompact ? MobileDesign.Spacing.medium : MobileDesign.Spacing.large)
            .frame(maxWidth: .infinity, minHeight: isCompact ? 132 : 176, alignment: .topLeading)
            .background(NotebookTint.color(for: notebook.id), in: shape)
            .contentShape(shape)
            .contentShape(.hoverEffect, shape)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityIdentifier("browser.notebookRow")
        .overlay(alignment: isCompact ? .topTrailing : .bottomTrailing) {
            if hasOverview {
                MobileNotebookCardPlayButton(
                    overviewIsPlaying: overviewIsPlaying,
                    isPreparingOverview: isPreparingOverview,
                    onPlay: onPlay
                )
                .padding(isCompact ? MobileDesign.Spacing.xSmall : MobileDesign.Spacing.small)
            }
        }
    }
}
