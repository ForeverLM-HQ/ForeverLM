// The Home list of saved unread sources and its rows.
import SwiftUI
import AppKit

// MARK: - Home's To Read list

/// What the learner saved and has not finished, under Home's composer: a
/// quiet head, then one row a source with its thumbnail, its title and
/// where and when it was saved, newest first, with no card around a row.
/// A row opens the source in the Reader; the
/// foot opens the Library on Recent, every kind newest added first.
struct HomeToReadList: View {
    let sources: [StudioArticle]
    /// Everything waiting, of which `sources` is the newest.
    let totalCount: Int
    let open: (String) -> Void
    /// Nil where the chat has no window to open the Library in.
    let showAll: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("To read")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.leading, 10)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            ForEach(sources) { source in
                HomeToReadRow(source: source) { open(source.id) }
            }
            if let showAll {
                Button(action: showAll) {
                    Text(totalCount > sources.count
                         ? "All \(totalCount) in the Library"
                         : "Everything you've added")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hoverWash)
                .help("Open the Library on Recent: every source, newest added first")
                .accessibilityIdentifier("home.toRead.showAll")
            }
        }
        .padding(.horizontal, StudioDesign.Spacing.small)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("To read")
        .accessibilityIdentifier("home.toRead")
    }
}

private struct HomeToReadRow: View {
    let source: StudioArticle
    let open: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                // The source's own picture, as the Library's rows show it
                // (product owner, 2026-11-11: "It would be nice to have these
                // things also at the thumbnails"); its kind's glyph where it
                // has none.
                SourceThumbnail(source: source, size: 28)
                Text(source.title.isEmpty ? source.url : source.title)
                    .font(.system(size: 13))
                    .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Color.primary.opacity(isHovered ? 0.05 : 0),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(source.title)
        .accessibilityIdentifier("home.toRead.row")
    }

    /// Where it came from and when it was saved: a paper's journal, else the
    /// site, then the day ("Today", "Yesterday", or the date).
    private var detail: String {
        var parts: [String] = []
        if source.sourceType == .paper, let journal = source.journal, !journal.isEmpty,
           journal != StudioArticle.unknownPaperJournal {
            parts.append(journal)
        } else if !source.domain.isEmpty {
            parts.append(source.domain.hasPrefix("www.") ? String(source.domain.dropFirst(4)) : source.domain)
        }
        let calendar = Calendar.current
        if calendar.isDateInToday(source.dateAdded) {
            parts.append("Today")
        } else if calendar.isDateInYesterday(source.dateAdded) {
            parts.append("Yesterday")
        } else {
            parts.append(source.dateAdded.formatted(.dateTime.month(.abbreviated).day()))
        }
        return parts.joined(separator: " · ")
    }
}
