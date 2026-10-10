import AppKit
import SwiftUI

/// "New in journals" at the top of a Notebook's source pool: the articles a
/// followed journal published that the matching call judged to belong here,
/// each waiting for one of two answers. Add imports the article and puts it
/// in the pool; dismiss is a tombstone. Nothing is in the library until the
/// learner has said so (docs/journals-design.md).
struct NotebookJournalSuggestionsSection: View {
    @Environment(StudioViewModel.self) private var vm
    let goal: LearningGoalRecord
    let searchTerms: [String]

    private var runner: JournalWatchRunner { JournalWatchRunner.shared }
    /// Rows the learner has answered this session, hidden immediately so the
    /// list does not wait for the reload.
    @State private var decidedIDs: Set<String> = []

    private var suggestions: [JournalArticleSuggestion] {
        runner.suggestions(for: goal.id).filter { suggestion in
            guard !decidedIDs.contains(suggestion.id) else { return false }
            guard !searchTerms.isEmpty else { return true }
            let haystack = [suggestion.item.title, suggestion.journalName, suggestion.item.authors ?? "", suggestion.match.reason ?? ""]
                .joined(separator: " ")
            return NotebookContextSourceSearch.matchesText(haystack, terms: searchTerms)
        }
    }

    var body: some View {
        let rows = suggestions
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Image(systemName: "newspaper")
                        .zoomedSystemFont(size: 10, weight: .semibold)
                    Text("New from your feeds")
                        .zoomedSystemFont(size: 11, weight: .semibold)
                    Text("\(rows.count)")
                        .zoomedSystemFont(size: 10, weight: .medium)
                        .foregroundStyle(.tertiary)
                    Rectangle()
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 1)
                }
                .foregroundStyle(.secondary)
                ForEach(rows) { suggestion in
                    row(suggestion)
                }
            }
            .onChange(of: runner.suggestions.map(\.id)) { _, _ in
                // The reload has landed; the session-local hiding can go.
                decidedIDs = []
            }
        }
    }

    private func row(_ suggestion: JournalArticleSuggestion) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Button {
                if let url = URL(string: suggestion.item.itemURL) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(byline(suggestion))
                        .zoomedSystemFont(size: 10, weight: .medium)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Text(suggestion.item.title)
                        .zoomedSystemFont(size: 12, weight: .medium)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let reason = suggestion.match.reason, !reason.isEmpty {
                        Text(reason)
                            .zoomedSystemFont(size: 11)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: -3))
            .help("Open the article")

            Button {
                decidedIDs.insert(suggestion.id)
                Task { await vm.acceptJournalSuggestion(suggestion) }
            } label: {
                Image(systemName: "checkmark")
            }
            .buttonStyle(.hoverWash)
            .help("Add to this notebook")
            .accessibilityLabel("Add \(suggestion.item.title) to this notebook")

            Button {
                decidedIDs.insert(suggestion.id)
                Task { await vm.dismissJournalSuggestion(suggestion) }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.hoverWash)
            .help("Not for this notebook")
            .accessibilityLabel("Dismiss \(suggestion.item.title)")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    private func byline(_ suggestion: JournalArticleSuggestion) -> String {
        var parts = [suggestion.journalName]
        if let published = suggestion.item.publishedAt {
            parts.append(published.formatted(.dateTime.day().month(.abbreviated)))
        }
        if let authors = suggestion.item.authors, !authors.isEmpty {
            parts.append(authors)
        }
        return parts.joined(separator: " · ")
    }
}
