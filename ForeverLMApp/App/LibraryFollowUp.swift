import OSLog
import SwiftUI

// MARK: - The Library's Follow up scope

private let followUpLogger = Logger(subsystem: "com.foreverlm.app", category: "FollowUp")

extension StudioViewModel {
    /// The marks to list: set aside to follow up (blue) or doubt (pink), on
    /// sources the learner has not put away, newest first. The rule is
    /// `FollowUpList`'s. A mark on a source this window does not list stays
    /// out, so every row can open its source.
    var followUpMarks: [FollowUpMark] {
        let byID = articlesById
        return FollowUpList.open(followUpMarkStore) { sourceID in
            guard let article = byID[sourceID] else { return true }
            return article.isHidden || article.archivedAt != nil || !isVisibleInRecordingMode(article)
        }
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

/// The Follow up list: every passage set aside to follow up (blue) or doubt
/// (pink), across the library, under Today, Yesterday, This Week and Earlier.
/// A row opens its source in the Reader with the mark's card; its check (on
/// hover) and the row menu mark it followed up, which takes it off the list.
struct LibraryFollowUpList: View {
    let marks: [FollowUpMark]

    var body: some View {
        if marks.isEmpty {
            VStack(spacing: 6) {
                SpaceEmptyLine(systemImage: "checkmark.circle", text: "Nothing to follow up")
                Text("Mark a passage blue (Follow up) or pink (Doubt) while you read.")
                    .zoomedSystemFont(size: 12, weight: .regular)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let sections = ToReadList.sections(marks, dateAdded: { $0.highlight.createdAt }, now: Date())
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, group in
                        Text(group.section.title)
                            .zoomedSystemFont(size: 12, weight: .semibold)
                            .foregroundStyle(.secondary)
                            .textSelection(.disabled)
                            .padding(.horizontal, 14)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                        ForEach(group.items) { mark in
                            LibraryFollowUpRow(mark: mark)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
            }
            .accessibilityIdentifier("library.followUp.list")
        }
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

    /// What the color says, where it came from, and when it was marked.
    private var detail: String {
        var parts = [highlight.color.meaning]
        if let title = vm.articlesById[mark.sourceID]?.title, !title.isEmpty { parts.append(title) }
        parts.append(highlight.createdAt.formatted(date: .abbreviated, time: .omitted))
        return parts.joined(separator: " · ")
    }
}
