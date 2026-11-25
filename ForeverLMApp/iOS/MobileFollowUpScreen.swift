import SwiftUI

/// The Follow up screen, the row under Home's To Read: every passage the
/// learner flagged to follow up, whatever its color, across the library,
/// newest first under Today, Yesterday, This Week and Earlier. The rule is
/// `FollowUpList`'s, the one the Mac's Library Follow up scope reads. A row
/// opens the source in the Reader; a swipe, or Followed Up in its menu, takes
/// the flag off, which takes it off the list. The color stays as it was.
struct MobileFollowUpScreen: View {
    @EnvironmentObject private var vm: MobileAudioReviewViewModel

    /// Every open mark the phone holds, read from the catalog's replica and
    /// kept in step with what this screen changes.
    @State private var stored: [FollowUpMark] = []
    @State private var hasLoaded = false
    @State private var saveError: String?

    /// The marks to list: on sources the phone holds and the learner has not
    /// put away, in the rule's order.
    private var marks: [FollowUpMark] {
        let byID = vm.sourcesByID
        return FollowUpList.open(stored) { sourceID in
            guard let source = byID[sourceID] else { return true }
            return source.isArchived || source.isHidden
        }
    }

    var body: some View {
        let marks = marks
        Group {
            if marks.isEmpty {
                VStack(spacing: 6) {
                    Text(hasLoaded ? "Nothing to follow up" : "Loading…")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    if hasLoaded {
                        Text("Flag a highlight to follow up while you read on your Mac.")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let sections = ToReadList.sections(marks, dateAdded: { $0.highlight.createdAt }, now: Date())
                List {
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, group in
                        Section(group.section.title) {
                            ForEach(group.items) { mark in
                                MobileFollowUpRow(mark: mark) { changed in
                                    Task { await save(changed) }
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .accessibilityIdentifier("followUp.list")
            }
        }
        .navigationTitle("Follow Up")
        .navigationBarTitleDisplayMode(.large)
        .task { await load(forceRefresh: false) }
        .refreshable { await load(forceRefresh: true) }
        .alert(
            "Highlight could not be saved",
            isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } }),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(saveError ?? "") }
        )
    }

    private func load(forceRefresh: Bool) async {
        do {
            stored = try await MobileCloudSourceCatalog.shared.loadOpenSourceHighlights(forceRefresh: forceRefresh)
            hasLoaded = true
        } catch {
            // A failed refresh keeps what is shown; a first load shows the empty line.
            hasLoaded = true
        }
    }

    private func save(_ changed: SourceHighlight) async {
        guard let source = vm.sourcesByID[changed.sourceID] else { return }
        var highlight = changed
        highlight.updatedAt = Date()
        do {
            try await MobileCloudMutationService.shared.saveSourceHighlight(highlight, source: source)
            stored = FollowUpList.applying(highlight, to: stored)
        } catch {
            saveError = MobileCloudKitRetry.describe(error)
        }
    }
}

private struct MobileFollowUpRow: View {
    let mark: FollowUpMark
    /// Saves the mark as changed here.
    let save: (SourceHighlight) -> Void
    @EnvironmentObject private var vm: MobileAudioReviewViewModel

    private var highlight: SourceHighlight { mark.highlight }

    var body: some View {
        // A destination, not a typed route: it opens on top of the screen it
        // was tapped on (the Library's rows do the same).
        NavigationLink {
            MobileShellSourceDestination(sourceID: mark.sourceID, notebookID: nil)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Self.swatch(highlight.color))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 3) {
                    // A mark on a picture has no words; its row names the picture.
                    Text(highlight.isPictureOnly ? highlight.pictureLabel : highlight.quote)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                    if highlight.hasNote {
                        Text(highlight.note)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityIdentifier("followUp.row")
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                settle()
            } label: {
                Label("Followed Up", systemImage: "checkmark.circle")
            }
            .tint(.accentColor)
        }
        .contextMenu {
            Button("Followed Up", systemImage: "checkmark.circle") { settle() }
            Menu("Color") {
                ForEach(SourceHighlightColor.allCases, id: \.rawValue) { option in
                    Button {
                        guard option != highlight.color else { return }
                        var changed = highlight
                        changed.color = option
                        save(changed)
                    } label: {
                        if option == highlight.color {
                            Label(option.meaning, systemImage: "checkmark")
                        } else {
                            Text(option.meaning)
                        }
                    }
                }
            }
        }
    }

    /// Followed up: the flag comes off; the color stays.
    private func settle() {
        var changed = highlight
        changed.followUpAt = nil
        save(changed)
    }

    /// What the color says, where it came from, and when it was marked.
    private var detail: String {
        var parts = [highlight.color.meaning]
        if let title = vm.sourcesByID[mark.sourceID]?.title, !title.isEmpty { parts.append(title) }
        parts.append(highlight.createdAt.formatted(date: .abbreviated, time: .omitted))
        return parts.joined(separator: " · ")
    }

    private static func swatch(_ color: SourceHighlightColor) -> Color {
        let rgb = color.components
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}
