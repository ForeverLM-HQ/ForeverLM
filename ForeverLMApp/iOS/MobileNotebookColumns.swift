import SwiftUI

extension View {
    /// On a screen roomy enough (`MobileNotebookColumnLayout.usesColumns`: an
    /// iPad, or an iPhone Duo opened), the notebook's three tabs side by side
    /// in place of this view — the tabs and their bar — and this view as it is
    /// everywhere else. `onLayoutChange` runs when a screen moves between the
    /// two, as a window is resized, the device turned or the Duo folded.
    func mobileNotebookColumns(
        notebook: MobileCloudNotebook,
        selection: MobileNotebookChatSelectionStore,
        session: MobileNotebookChatSession,
        onAddSources: @escaping () -> Void,
        onLayoutChange: @escaping () -> Void
    ) -> some View {
        modifier(MobileNotebookColumnsSwitch(
            notebook: notebook,
            selection: selection,
            session: session,
            onAddSources: onAddSources,
            onLayoutChange: onLayoutChange
        ))
    }
}

/// Chooses between the tabs and the columns by the notebook's own width and
/// the size classes it was given, never by the device: a Duo's inner display
/// reports an iPad's classes, its outer display a phone's, and the one app
/// moves between them as the device folds. The measuring wrapper is the same
/// on every device, so the tabs keep their identity (and their state) across
/// every resize that keeps them.
private struct MobileNotebookColumnsSwitch: ViewModifier {
    let notebook: MobileCloudNotebook
    let selection: MobileNotebookChatSelectionStore
    let session: MobileNotebookChatSession
    let onAddSources: () -> Void
    let onLayoutChange: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            let usesColumns = MobileNotebookColumnLayout.usesColumns(
                isRegularWidth: horizontalSizeClass == .regular,
                isRegularHeight: verticalSizeClass == .regular,
                width: proxy.size.width
            )
            Group {
                if usesColumns {
                    MobileNotebookColumns(
                        notebook: notebook,
                        selection: selection,
                        session: session,
                        totalWidth: proxy.size.width,
                        onAddSources: onAddSources
                    )
                } else {
                    content
                }
            }
            .onChange(of: usesColumns) { _, _ in onLayoutChange() }
        }
    }
}

/// A notebook on a wide screen (an iPad, an iPhone Duo opened), as the Mac
/// draws it (docs/notebooks-design.md, "The notebook workspace"): the
/// notebook's **Sources** on the left, its **Chat** in the middle, its
/// **Studio** on the right, hairlines between.
/// Each side folds to a strip — the way back and the column's main action —
/// and stays folded on this device (`MobileNotebookColumnLayout.foldedKey`)
/// until it is shown again. The columns are the tabs themselves, as they are;
/// a source, a chat or a Doc opened from one is pushed over the notebook as
/// it is from a tab. The chat's sources chip opens the chat's Sources sheet
/// here as it does on the phone.
struct MobileNotebookColumns: View {
    let notebook: MobileCloudNotebook
    let selection: MobileNotebookChatSelectionStore
    let session: MobileNotebookChatSession
    let totalWidth: CGFloat
    let onAddSources: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(MobileNotebookColumnLayout.foldedKey(.sources)) private var sourcesFolded
    @AppStorage(MobileNotebookColumnLayout.foldedKey(.studio)) private var studioFolded
    @AccessibilityFocusState private var focusesSourcesHeader: Bool
    @AccessibilityFocusState private var focusesStudioHeader: Bool

    private typealias Layout = MobileNotebookColumnLayout

    var body: some View {
        HStack(spacing: 0) {
            sourcesColumn
                .frame(width: Layout.width(folded: sourcesFolded, totalWidth: totalWidth))
            Divider()
            MobileNotebookChatTab(
                notebook: notebook,
                selection: selection,
                session: session,
                // No tab bar to make room for the keyboard here: the
                // composer's focus writes nowhere.
                hidesTabBar: .constant(false),
                onAddSources: onAddSources
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Chat")
            Divider()
            studioColumn
                .frame(width: Layout.width(folded: studioFolded, totalWidth: totalWidth))
        }
    }

    // MARK: - Sources

    @ViewBuilder
    private var sourcesColumn: some View {
        Group {
            if sourcesFolded {
                MobileNotebookColumnStrip {
                    MobileNotebookStripButton(
                        systemImage: "sidebar.left",
                        label: "Show Sources",
                        identifier: "notebook.sources.expand"
                    ) {
                        setFolded(.sources, false)
                    }
                    MobileNotebookStripButton(
                        systemImage: "plus",
                        label: "Add sources",
                        identifier: "notebook.sources.stripAdd",
                        action: onAddSources
                    )
                }
            } else {
                VStack(spacing: 0) {
                    MobileNotebookColumnHeader(
                        title: "Sources",
                        foldSymbol: "sidebar.left",
                        foldLabel: "Hide Sources",
                        foldIdentifier: "notebook.sources.collapse",
                        titleFocus: $focusesSourcesHeader
                    ) {
                        setFolded(.sources, true)
                    }
                    MobileNotebookSourcesTab(
                        notebook: notebook,
                        selection: selection,
                        onAddSources: onAddSources
                    )
                }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground), ignoresSafeAreaEdges: .all)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sources")
    }

    // MARK: - Studio

    @ViewBuilder
    private var studioColumn: some View {
        Group {
            if studioFolded {
                MobileNotebookColumnStrip {
                    MobileNotebookStripButton(
                        systemImage: "sidebar.right",
                        label: "Show Studio",
                        identifier: "notebook.studio.expand"
                    ) {
                        setFolded(.studio, false)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    MobileNotebookColumnHeader(
                        title: "Studio",
                        foldSymbol: "sidebar.right",
                        foldLabel: "Hide Studio",
                        foldIdentifier: "notebook.studio.collapse",
                        titleFocus: $focusesStudioHeader
                    ) {
                        setFolded(.studio, true)
                    }
                    MobileNotebookStudioTab(notebook: notebook)
                }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground), ignoresSafeAreaEdges: .all)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Studio")
    }

    // MARK: - Folding

    private func setFolded(_ side: Layout.Side, _ folded: Bool) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
            switch side {
            case .sources: sourcesFolded = folded
            case .studio: studioFolded = folded
            }
        }
    }
}

/// An open side column's title row, the Mac's chrome-line header: the
/// column's name and, at its trailing edge, the fold.
private struct MobileNotebookColumnHeader: View {
    let title: String
    let foldSymbol: String
    let foldLabel: String
    let foldIdentifier: String
    /// Moves VoiceOver to the column's name.
    let titleFocus: AccessibilityFocusState<Bool>.Binding
    let fold: () -> Void

    var body: some View {
        HStack(spacing: MobileDesign.Spacing.small) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused(titleFocus)
            Spacer(minLength: 0)
            Button(action: fold) {
                Image(systemName: foldSymbol)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(
                        width: MobileDesign.Metrics.minimumTouchTarget,
                        height: MobileDesign.Metrics.minimumTouchTarget
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel(foldLabel)
            .accessibilityIdentifier(foldIdentifier)
        }
        .padding(.leading, MobileDesign.Spacing.large)
        .padding(.trailing, MobileDesign.Spacing.xSmall)
        .frame(minHeight: MobileDesign.Metrics.minimumTouchTarget)
    }
}

/// A folded side column, Gemini's and the Mac's strip: its buttons stacked
/// from the top.
private struct MobileNotebookColumnStrip<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: MobileDesign.Spacing.xSmall) {
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// One of a strip's buttons: a glyph on a full 44-point target.
private struct MobileNotebookStripButton: View {
    let systemImage: String
    let label: String
    let identifier: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(
                    width: MobileDesign.Metrics.minimumTouchTarget,
                    height: MobileDesign.Metrics.minimumTouchTarget
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}
