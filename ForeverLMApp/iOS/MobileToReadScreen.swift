import SwiftUI

/// The To Read screen, the row under Home's Library: what the learner saved
/// and has not finished, newest saved first, under Today, Yesterday, This
/// Week and Earlier. The rule is `ToReadList`'s, the one the Mac's Library
/// To Read scope reads. A row opens the source in the Reader; a swipe marks
/// it read, which takes it off the list (the Mac's Mark as Read).
struct MobileToReadScreen: View {
    @EnvironmentObject private var vm: MobileAudioReviewViewModel

    /// The sources waiting, in the rule's order.
    private var waiting: [MobileCloudSource] {
        let byID = vm.sourcesByID
        return ToReadList.waiting(vm.allSources.map(MobileToReadRules.candidate)).compactMap { byID[$0.id] }
    }

    var body: some View {
        let waiting = waiting
        Group {
            if waiting.isEmpty {
                Text("Nothing waiting")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let sections = ToReadList.sections(waiting, dateAdded: \.dateAdded, now: Date())
                List {
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, group in
                        Section(group.section.title) {
                            ForEach(group.items) { source in
                                MobileToReadRow(source: source)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .accessibilityIdentifier("toRead.list")
            }
        }
        .navigationTitle("To Read")
        .navigationBarTitleDisplayMode(.large)
    }
}

/// What `ToReadList` is given for a synced source.
enum MobileToReadRules {
    static func candidate(_ source: MobileCloudSource) -> ToReadCandidate {
        ToReadCandidate(
            id: source.id,
            sourceType: source.sourceType,
            dateAdded: source.dateAdded,
            isFinished: source.readAt != nil || source.isWatched,
            isPutAway: source.isArchived || source.isHidden,
            isPaywalled: source.isPaywalled,
            belongsToGroup: source.parentGroup != nil,
            isSpokenScript: MobileSourceListing.isSpokenScript(source)
        )
    }

    /// Where it came from and when it was saved, under its title: the site
    /// (a paper's journal or author), then the day.
    static func detail(_ source: MobileCloudSource) -> String {
        var parts: [String] = []
        if source.sourceType == "paper" {
            if let journal = source.journal, !journal.isEmpty {
                parts.append(journal)
            } else if let author = source.author, !author.isEmpty {
                parts.append(author)
            }
        } else if let host = source.url.flatMap({ URL(string: $0)?.host }), !host.isEmpty {
            parts.append(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
        }
        parts.append(source.dateAdded.formatted(date: .abbreviated, time: .omitted))
        return parts.joined(separator: " · ")
    }
}

private struct MobileToReadRow: View {
    let source: MobileCloudSource
    @EnvironmentObject private var vm: MobileAudioReviewViewModel

    var body: some View {
        // A destination, not a typed route: it opens on top of the screen it
        // was tapped on (the Library's rows do the same).
        NavigationLink {
            MobileShellSourceDestination(sourceID: source.id, notebookID: nil)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(source.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(MobileToReadRules.detail(source))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 2)
        }
        .accessibilityIdentifier("toRead.row")
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            // A source still being fetched cannot be logged read yet.
            if source.state == "ready" {
                Button {
                    Task { _ = await vm.recordExternalSourceCompletions(sourceIDs: [source.id], kind: .reading) }
                } label: {
                    Label("Mark as Read", systemImage: "checkmark.circle")
                }
                .tint(.accentColor)
            }
        }
    }
}
