import OSLog
import SwiftUI

// MARK: - Passages set aside to follow up, on the Library's rows

private let followUpLogger = Logger(subsystem: "com.foreverlm.app", category: "FollowUp")

extension StudioViewModel {
    /// One source's marks flagged to follow up, newest first, by
    /// `FollowUpList`'s rule. What its Library row's
    /// flag counts and lists. The row is the source's, so whether the source
    /// is put away is the list's business, not this.
    func followUpMarks(forSource sourceID: String) -> [FollowUpMark] {
        let marks = followUpMarkStore.filter { $0.sourceID == sourceID }
        guard !marks.isEmpty else { return [] }
        return FollowUpList.open(marks) { _ in false }
    }

    /// Reads every flagged mark from storage. The list is kept in step with
    /// flags set in the Reader afterwards (`applyLocally`); this
    /// catches what arrived by sync or from an assistant since.
    func reloadFollowUpMarks() async {
        do {
            followUpMarkStore = try await storage.openSourceHighlights()
            followUpMarksLoaded = true
        } catch {
            followUpLogger.error("Could not read the follow-up marks: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Opens the mark's source in the Reader with the mark's card on it: the
    /// passage, the learner's note and the colors. Opening writes nothing.
    func openFollowUpMark(_ mark: FollowUpMark) async {
        await revealSourceInReader(mark.sourceID)
        await loadReaderHighlightsIfNeeded(for: mark.sourceID)
        openReaderHighlight(highlightID: mark.id, sourceID: mark.sourceID)
    }

    /// Followed up: the flag comes off and the mark leaves the list. Its
    /// color, which says what the passage is, stays as it was.
    func settleFollowUpMark(_ mark: FollowUpMark) async {
        await loadReaderHighlightsIfNeeded(for: mark.sourceID)
        await setReaderHighlightFollowUp(false, highlightID: mark.id, sourceID: mark.sourceID)
    }

    func setFollowUpMarkColor(_ mark: FollowUpMark, to color: SourceHighlightColor) async {
        await loadReaderHighlightsIfNeeded(for: mark.sourceID)
        await setReaderNoteColor(color, highlightID: mark.id, sourceID: mark.sourceID)
    }
}

/// A Library row's one trailer: "To follow up" when passages are flagged
/// to follow up, in the row's grey ("Lists are monochrome",
/// docs/ui-design.md); nothing otherwise. A row never names its cards (product
/// owner, 2026-11-22: "i don't want any cards to be linked here in the
/// library"). A click opens the source's cards and, under them, the waiting
/// passages, each opening the Reader at its mark, with its check to mark it
/// followed up; the popover ends with Write Card (Write Another Card once it
/// has some).
struct SourceCardsTrailer: View {
    @Environment(StudioViewModel.self) private var vm
    /// The window the row is in, where Write Card opens the source.
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?
    let sourceID: String
    @State private var isListing = false

    var body: some View {
        let followUps = vm.followUpMarks(forSource: sourceID).count
        if followUps > 0 {
            let label = "To follow up"
            Button {
                isListing = true
            } label: {
                Text(label)
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .frame(height: 16)
                    .contentShape(Capsule())
            }
            // The press is the trailer's, so the row does not also open its
            // source under it (`SidebarRowControlPress`).
            .buttonStyle(RowControlButtonStyle(
                sourceIDs: [sourceID],
                wash: .hoverWash(in: Capsule(), inset: 0, opacity: 0.08)
            ))
            .fixedSize()
            .help(help(followUps: followUps))
            .accessibilityLabel(help(followUps: followUps))
            .accessibilityIdentifier("library.cards.trailer.\(sourceID)")
            .popover(isPresented: $isListing, arrowEdge: .bottom) {
                SourceCardsPopover(
                    sourceID: sourceID,
                    writeCardTitle: vm.sourceCardCoverage.statesByID[sourceID]?.makeCardsTitle ?? "Write Card",
                    writeCard: writeCard
                )
                .environment(vm)
            }
        }
    }

    /// The source in the Reader with a blank card beside it
    /// (`requestWriteCards`).
    private func writeCard() {
        isListing = false
        let ids = [sourceID]
        if let windowState {
            vm.inWindow(windowState) { vm.requestWriteCards(notebookID: nil, sourceIDs: ids) }
        } else {
            vm.requestWriteCards(notebookID: nil, sourceIDs: ids)
        }
    }

    private func help(followUps: Int) -> String {
        followUps == 1 ? "1 passage to follow up" : "\(followUps) passages to follow up"
    }
}

extension StudioViewModel {
    /// The kept cards on one source, newest first; none when they cannot be
    /// read, and the reason logged.
    func keptCards(onSource sourceID: String) async -> [MemoryItem] {
        do {
            return try await storage.keptCards(onSource: sourceID)
        } catch {
            followUpLogger.error("The cards of a source could not be read: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}

/// The trailer's popover: the source's kept cards, then its open marks,
/// newest first, then Write Card. The marks are read live, so one checked
/// here leaves at once.
private struct SourceCardsPopover: View {
    @Environment(StudioViewModel.self) private var vm
    let sourceID: String
    let writeCardTitle: String
    let writeCard: () -> Void
    @State private var cards: [MemoryItem] = []

    var body: some View {
        let marks = vm.followUpMarks(forSource: sourceID)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !cards.isEmpty {
                    heading(cards.count == 1 ? "1 Card" : "\(cards.count) Cards")
                    ForEach(cards) { item in
                        KeptCardRow(item: item, sourceID: sourceID)
                    }
                }
                if !marks.isEmpty {
                    heading("To Follow Up")
                    Text("Highlights you flagged to follow up while reading.")
                        .zoomedSystemFont(size: 11.5)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 4)
                    ForEach(marks) { mark in
                        LibraryFollowUpRow(mark: mark)
                            .padding(.horizontal, 6)
                    }
                }
            }
            .padding(.bottom, 4)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button(writeCardTitle, systemImage: "square.and.pencil", action: writeCard)
                    .buttonStyle(.hoverWash)
                    .zoomedSystemFont(size: 12, weight: .medium)
                    .accessibilityIdentifier("library.cards.write")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(width: 380)
        .frame(maxHeight: 480)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: vm.memoryCardRevision) {
            cards = await vm.keptCards(onSource: sourceID)
        }
        .accessibilityIdentifier("library.cards.popover")
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .zoomedSystemFont(size: 12, weight: .semibold)
            .foregroundStyle(.secondary)
            .textSelection(.disabled)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }
}

/// One kept card: its front, its back faint under it. A click opens the
/// source the card stands on.
private struct KeptCardRow: View {
    @Environment(StudioViewModel.self) private var vm
    let item: MemoryItem
    let sourceID: String

    var body: some View {
        let card = MemoryCard(storedIn: item)
        Button {
            Task { await vm.revealSourceInReader(sourceID) }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text((card?.front ?? item.target).cardFaceText())
                    .zoomedSystemFont(size: 13, weight: .medium)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                if let back = card?.backWords {
                    Text(back.cardFaceText())
                        .zoomedSystemFont(size: 12)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 8, inset: 0))
        .padding(.horizontal, 6)
        .accessibilityIdentifier("library.cards.card")
    }
}

private struct LibraryFollowUpRow: View {
    @Environment(StudioViewModel.self) private var vm
    let mark: FollowUpMark
    @State private var isHovered = false

    private var highlight: SourceHighlight { mark.highlight }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                Task { await vm.openFollowUpMark(mark) }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(highlight.color.swatch)
                        .frame(width: 3)
                    VStack(alignment: .leading, spacing: 3) {
                        // A mark on a picture has no words; its row names the picture.
                        Text(highlight.isPictureOnly ? highlight.pictureLabel : highlight.quote)
                            .zoomedSystemFont(size: 13, weight: .medium)
                            .foregroundStyle(.primary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                        if highlight.hasNote {
                            Text(highlight.note)
                                .zoomedSystemFont(size: 12, weight: .regular)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        Text(detail)
                            .zoomedSystemFont(size: 11.5, weight: .regular)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 8, inset: 0))
            .accessibilityIdentifier("library.followUp.row")

            if isHovered {
                Button {
                    Task { await vm.settleFollowUpMark(mark) }
                } label: {
                    Image(systemName: "checkmark.circle")
                        .zoomedSystemFont(size: 15, weight: .regular)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.hoverWash(cornerRadius: 8, inset: 0))
                .help("Followed Up")
                .accessibilityLabel("Followed Up")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Open", systemImage: "arrow.up.forward.square") {
                Task { await vm.openFollowUpMark(mark) }
            }
            OtherWindowSourceMenuItem(sourceID: mark.sourceID)
            Divider()
            Button("Followed Up", systemImage: "checkmark.circle") {
                Task { await vm.settleFollowUpMark(mark) }
            }
            Menu("Color") {
                ForEach(SourceHighlightColor.allCases, id: \.self) { option in
                    HighlightColorMenuRow(color: option, isSelected: option == highlight.color) {
                        Task { await vm.setFollowUpMarkColor(mark, to: option) }
                    }
                }
            }
        }
    }

    /// What the color says and when it was marked. The source is the
    /// popover's, named by the row the flag is on.
    private var detail: String {
        [highlight.color.meaning, highlight.createdAt.formatted(date: .abbreviated, time: .omitted)]
            .joined(separator: " · ")
    }
}
