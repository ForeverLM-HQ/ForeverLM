import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    /// Asks whichever reader is showing a source to scroll one of its
    /// highlights into view. The object is a `ReaderHighlightRevealRequest`.
    ///
    /// A notification rather than view-model state because the three reader
    /// engines are AppKit coordinators well below the SwiftUI tree that owns
    /// the notes list, and each knows how to reveal a passage in its own terms.
    static let revealReaderHighlight = Notification.Name("revealReaderHighlight")
}

struct ReaderHighlightRevealRequest {
    let sourceID: String
    let highlightID: String
}

/// The reader's per-source notes column.
///
/// Reading order, not recency: notes are a map of the source, and a list that
/// reshuffles when you edit one stops being a map.
struct ReaderNotesList: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(\.uiZoomScale) private var uiZoomScale

    let sourceID: String

    /// The marks on the source. A talk's slide laid out on a canvas is a mark
    /// too (`ReaderClip.slideHighlight`), but the slides are already in the
    /// reader; one is listed only once the learner has written on it.
    private var highlights: [SourceHighlight] {
        vm.highlights(for: sourceID).filter { ReaderClip.slide(of: $0) == nil || $0.hasNote }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if highlights.isEmpty {
                empty
            } else {
                list
            }
        }
        .frame(width: 280 * uiZoomScale)
        .background(.background.secondary)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Highlights")
                .font(.subheadline.weight(.semibold))
            if !highlights.isEmpty {
                Text("\(highlights.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                vm.readerNotesListVisible = false
            } label: {
                Image(systemName: "sidebar.right")
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash)
            .help("Hide highlights")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "highlighter")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("Nothing highlighted yet")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Select text in the source, then press Highlight. A comment is optional.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(highlights) { highlight in
                    ReaderNoteRow(highlight: highlight)
                    Divider().padding(.leading, 12)
                }
            }
        }
    }
}

private struct ReaderNoteRow: View {
    @Environment(StudioViewModel.self) private var vm
    let highlight: SourceHighlight

    @State private var isHovering = false
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?

    /// The passage as it drags onto a canvas; nil for a mark that is not one.
    private func passageProvider() -> NSItemProvider? {
        guard vm.listsCanvases, let transfer = StudioClipTransfer(passage: highlight),
              let data = try? JSONEncoder().encode(transfer) else { return nil }
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.studioClip.identifier, visibility: .ownProcess) { done in
            done(data, nil)
            return nil
        }
        return provider
    }

    /// Whether the row has words of its own under the passage, which then
    /// steps back.
    private var isAnnotated: Bool {
        highlight.hasNote || highlight.hasPublicationUpdate
    }

    var body: some View {
        Button(action: reveal) {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(swatchColor)
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: 4) {
                    // A mark on a picture has no words; its row names the
                    // picture instead, with the symbol that says so.
                    if highlight.isPictureOnly {
                        Label(highlight.pictureLabel, systemImage: "photo")
                            .font(.caption)
                            .foregroundStyle(isAnnotated ? .secondary : .primary)
                            .lineLimit(2)
                    } else {
                        Text(highlight.quote)
                            .font(.caption)
                            .foregroundStyle(isAnnotated ? .secondary : .primary)
                            .lineLimit(isAnnotated ? 2 : 4)
                            .multilineTextAlignment(.leading)
                    }

                    // Research's update, marked as such, above the learner's
                    // own note.
                    if highlight.hasPublicationUpdate {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                            Text(highlight.publicationUpdate)
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .lineLimit(4)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if highlight.hasNote {
                        Text(highlight.note)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .lineLimit(6)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // A mark whose note came from a chat — What's New research, or
                // a chat an assistant linked — says so, and opens it.
                if let chatID = highlight.linkedChatID {
                    Button {
                        vm.openLinkedChat(chatID)
                    } label: {
                        Image(systemName: "bubble.left.and.text.bubble.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.hoverWash(inset: -2))
                    .help("Open the chat this note came from")
                    .accessibilityLabel("Open the chat this note came from")
                }

                if isHovering {
                    Button {
                        vm.openReaderHighlight(
                            highlightID: highlight.id,
                            sourceID: highlight.sourceID
                        )
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.hoverWash(inset: -2))
                    .help("Comment on this highlight")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .background(isHovering ? Color.primary.opacity(0.05) : .clear)
        .onDrag { passageProvider() ?? NSItemProvider() }
        .contextMenu {
            // A passage goes to the open canvas (Heptabase: drag a highlight
            // onto a whiteboard); beta with the Canvas.
            if vm.listsCanvases, ReaderClip.isPassage(highlight), let windowState {
                Button("Add to Canvas", systemImage: KnowledgeMap.symbolName) {
                    Task { await vm.addPassageToCanvas(highlight, in: windowState) }
                }
            }
            Button(highlight.hasNote ? "Edit Comment" : "Add Comment") {
                vm.openReaderHighlight(
                    highlightID: highlight.id,
                    sourceID: highlight.sourceID
                )
            }
            Menu("Color") {
                ForEach(SourceHighlightColor.allCases, id: \.self) { option in
                    Button(option.displayName) {
                        Task {
                            await vm.setReaderNoteColor(
                                option,
                                highlightID: highlight.id,
                                sourceID: highlight.sourceID
                            )
                        }
                    }
                }
            }
            if highlight.hasPublicationUpdate {
                Button("Remove Update") {
                    Task {
                        await vm.clearReaderPublicationUpdate(
                            highlightID: highlight.id,
                            sourceID: highlight.sourceID
                        )
                    }
                }
            }
            Divider()
            if !highlight.isPictureOnly {
                Button("Copy Passage") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(highlight.quote, forType: .string)
                }
            }
            Button("Chat About This") {
                vm.requestChatAboutHighlight(highlight)
            }
            if let chatID = highlight.linkedChatID {
                Button("Open Chat") {
                    vm.openLinkedChat(chatID)
                }
            } else if !highlight.isPictureOnly {
                Button(ReaderHighlightCardView.researchLabel) {
                    vm.requestResearchUpdate(for: highlight)
                }
            }
            Divider()
            Button("Delete", role: .destructive) {
                Task {
                    await vm.removeReaderHighlight(
                        highlightID: highlight.id,
                        sourceID: highlight.sourceID
                    )
                }
            }
        }
    }

    private func reveal() {
        NotificationCenter.default.post(
            name: .revealReaderHighlight,
            object: ReaderHighlightRevealRequest(
                sourceID: highlight.sourceID,
                highlightID: highlight.id
            )
        )
    }

    private var swatchColor: Color {
        let rgb = highlight.color.components
        return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }
}
