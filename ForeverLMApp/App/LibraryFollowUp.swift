import OSLog
import SwiftUI

// MARK: - Passages set aside to follow up, on the Library's rows

private let followUpLogger = Logger(subsystem: "com.foreverlm.app", category: "FollowUp")

extension StudioViewModel {
    /// One source's open marks: set aside to follow up (blue) or doubt
    /// (pink), newest first, by `FollowUpList`'s rule. What its Library row's
    /// flag counts and lists. The row is the source's, so whether the source
    /// is put away is the list's business, not this.
    func followUpMarks(forSource sourceID: String) -> [FollowUpMark] {
        let marks = followUpMarkStore.filter { $0.sourceID == sourceID }
        guard !marks.isEmpty else { return [] }
        return FollowUpList.open(marks) { _ in false }
    }

    /// Reads every open mark from storage. The list is kept in step with
    /// color changes made in the Reader afterwards (`applyLocally`); this
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

    /// Followed up: the mark is no longer open, so it goes back to the
    /// default color (Remember) and leaves the list. The learner can pick any
    /// other color from the row's menu.
    func settleFollowUpMark(_ mark: FollowUpMark) async {
        await loadReaderHighlightsIfNeeded(for: mark.sourceID)
        await setReaderNoteColor(.default, highlightID: mark.id, sourceID: mark.sourceID)
    }

    func setFollowUpMarkColor(_ mark: FollowUpMark, to color: SourceHighlightColor) async {
        await loadReaderHighlightsIfNeeded(for: mark.sourceID)
        await setReaderNoteColor(color, highlightID: mark.id, sourceID: mark.sourceID)
    }
}

/// A Library row's flag: how many passages of this source wait to be followed
/// up or doubted, beside its card count, in the row's grey ("Lists are
/// monochrome", docs/ui-design.md). Nothing while none waits. A click lists
/// them in a popover, each opening the Reader at its card, with its check to
/// mark it followed up (product owner, 2026-11-07: "each source I have to at
/// least like follow up on and at least write some kind of takeaway"). It
/// replaces the Library's Follow up scope, a second list of the same marks.
struct SourceFollowUpFlag: View {
    @Environment(StudioViewModel.self) private var vm
    let sourceID: String
    @State private var isListing = false

    var body: some View {
        let marks = vm.followUpMarks(forSource: sourceID)
        if !marks.isEmpty {
            let label = marks.count == 1 ? "1 passage to follow up" : "\(marks.count) passages to follow up"
            Button {
                isListing = true
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "flag")
                        .zoomedSystemFont(size: 10, weight: .medium)
                    Text("\(marks.count)")
                        .zoomedSystemFont(size: 11)
                        .monospacedDigit()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .frame(height: 16)
                .contentShape(Capsule())
            }
            // The press is the flag's, so the row does not also open its
            // source under it (`SidebarRowControlPress`).
            .buttonStyle(RowControlButtonStyle(
                sourceIDs: [sourceID],
                wash: .hoverWash(in: Capsule(), inset: 0, opacity: 0.08)
            ))
            .fixedSize()
            .help(label)
            .accessibilityLabel(label)
            .accessibilityIdentifier("library.followUp.flag.\(sourceID)")
            .popover(isPresented: $isListing, arrowEdge: .bottom) {
                SourceFollowUpPopover(sourceID: sourceID)
                    .environment(vm)
            }
        }
    }
}

/// The flag's popover: the source's open marks, newest first. It reads them
/// live, so a mark checked here leaves at once, and the popover closes on
/// its own once none is left.
private struct SourceFollowUpPopover: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    let sourceID: String

    var body: some View {
        let marks = vm.followUpMarks(forSource: sourceID)
        VStack(alignment: .leading, spacing: 0) {
            Text("To follow up")
                .zoomedSystemFont(size: 12, weight: .semibold)
                .foregroundStyle(.secondary)
                .textSelection(.disabled)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(marks) { mark in
                        LibraryFollowUpRow(mark: mark)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 420)
        }
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: marks.isEmpty) { _, isEmpty in
            if isEmpty { dismiss() }
        }
        .accessibilityIdentifier("library.followUp.popover")
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
