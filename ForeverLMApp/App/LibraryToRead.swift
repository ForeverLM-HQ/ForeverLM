import SwiftUI

// MARK: - The Library's To Read scope

/// What the full-window Library lists: every source by kind (`all`), the
/// one list of what was saved and is still waiting (`toRead`, `ToReadList`),
/// or the one list of passages set aside to follow up or doubt (`followUp`,
/// `FollowUpList`).
enum LibraryScope: Equatable {
    case all
    case toRead
    case followUp
}

extension StudioViewModel {
    /// The saved sources still waiting to be read, newest saved first: the
    /// rule is `ToReadList`'s, shared with the iPhone. A source the learner
    /// cannot mark read (a PDF article, a book) stays out, so every row here
    /// can leave the list.
    var toReadArticles: [StudioArticle] {
        let candidates = articles.compactMap { article -> ToReadCandidate? in
            guard article.cachedSupportsReadTracking, isVisibleInRecordingMode(article) else { return nil }
            return ToReadCandidate(
                id: article.id,
                sourceType: article.sourceType.rawValue,
                dateAdded: article.dateAdded,
                isFinished: article.isRead,
                isPutAway: article.isHidden || article.archivedAt != nil,
                isPaywalled: article.hasPaywallMarker,
                belongsToGroup: article.parentGroup != nil,
                isSpokenScript: GeneratedExplainer.isSpokenScriptURL(article.url)
            )
        }
        let byID = articlesById
        return ToReadList.waiting(candidates).compactMap { byID[$0.id] }
    }
}

/// The scopes, as the Space's scope pills draw a list's filters: All, To
/// Read and Follow up, each with how many wait. In flow under the pane's
/// chrome line; the titlebar band takes only icon buttons.
struct LibraryScopeRow: View {
    @Binding var scope: LibraryScope
    let toReadCount: Int
    let followUpCount: Int

    var body: some View {
        HStack(spacing: 4) {
            SpaceScopePill(title: "All", isSelected: scope == .all) { scope = .all }
            SpaceScopePill(title: "To Read", isSelected: scope == .toRead, count: toReadCount) { scope = .toRead }
            SpaceScopePill(title: "Follow up", isSelected: scope == .followUp, count: followUpCount) { scope = .followUp }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

/// The To Read list: what the learner saved and has not finished, under
/// Today, Yesterday, This Week and Earlier. A row opens the source in the
/// Reader beside it; its check (on hover) and the row menu mark it read,
/// which takes it off the list.
struct LibraryToReadList: View {
    @Environment(StudioViewModel.self) private var vm
    let articles: [StudioArticle]

    var body: some View {
        if articles.isEmpty {
            SpaceEmptyLine(systemImage: "checkmark.circle", text: "Nothing waiting")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let sections = ToReadList.sections(articles, dateAdded: \.dateAdded, now: Date())
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
                        ForEach(group.items) { article in
                            LibraryToReadRow(article: article)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
            }
            .accessibilityIdentifier("library.toRead.list")
        }
    }
}

private struct LibraryToReadRow: View {
    @Environment(StudioViewModel.self) private var vm
    let article: StudioArticle
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                Task { await vm.revealSourceInReader(article.id) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(article.title.isEmpty ? article.url : article.title)
                        .zoomedSystemFont(size: 13, weight: .medium)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(detail)
                        .zoomedSystemFont(size: 11.5, weight: .regular)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 8, inset: 0))
            .accessibilityIdentifier("library.toRead.row")

            if isHovered {
                Button {
                    Task { await vm.setArticleRead(article.id, read: true) }
                } label: {
                    Image(systemName: "checkmark.circle")
                        .zoomedSystemFont(size: 15, weight: .regular)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.hoverWash(cornerRadius: 8, inset: 0))
                .help("Mark as Read")
                .accessibilityLabel("Mark as Read")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Mark as Read", systemImage: "checkmark.circle") {
                Task { await vm.setArticleRead(article.id, read: true) }
            }
        }
    }

    /// Where it came from, what kind, when it was saved, and how long it is.
    private var detail: String {
        var parts: [String] = []
        if let domain = article.displayDomain { parts.append(domain) }
        switch article.sourceType {
        case .paper: parts.append("Paper")
        case .xPost: parts.append("X")
        default: break
        }
        parts.append(article.dateAdded.formatted(date: .abbreviated, time: .omitted))
        if let words = article.wordCount, words > 0 {
            parts.append("\(max(1, words / 200)) min")
        }
        return parts.joined(separator: " · ")
    }
}
