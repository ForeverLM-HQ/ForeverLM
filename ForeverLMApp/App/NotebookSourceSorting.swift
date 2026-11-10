// Grouping, sorting and chapter titles for the notebook source pool.
import SwiftUI
import Combine
import UniformTypeIdentifiers
import PDFKit
import WebKit
import AppKit

/// Canonical pool ordering for source types, mirroring the sidebar tab order so the
/// Notebook pool reads the same way the library does.
let notebookPoolTypeRank: [StudioSourceType: Int] = [
    .article: 0, .unclassified: 0, .manual: 0,
    .paper: 1,
    .book: 2,
    .course: 3,
    .meeting: 4,
    .podcast: 5,
    .video: 6,
    .xPost: 7,
]

/// The plural section header shown for each source type in the Notebook pool. Article,
/// manual, and still-unclassified web sources share the "Articles" bucket, mirroring
/// their shared rank above.
func notebookTypeSectionTitle(for type: StudioSourceType) -> String {
    switch type {
    case .article, .unclassified, .manual: return "Articles"
    case .paper: return "Papers"
    case .book: return "Books"
    case .course: return "Courses"
    case .meeting: return "Meetings"
    case .podcast: return "Podcasts"
    case .video: return "Videos"
    case .xPost: return "Posts"
    }
}

/// One type-grouped section of the Notebook pool (e.g. all Papers), its groups already
/// sorted alphabetically. `rank` orders the sections themselves by `notebookPoolTypeRank`.
struct NotebookTypeSection: Identifiable {
    let title: String
    let rank: Int
    let groups: [NotebookContextSourceGroup]
    var id: String { "\(rank)-\(title)" }
}

/// Groups a Notebook pool's sources into contiguous type runs — all papers together, then
/// books, and so on — with the stored (MCP-reorderable) study order preserved *within*
/// each type. Used for the flat Suggested and paywalled sections; the main approved list
/// groups these into per-type sections via `notebookTypeSections`.
func notebookContextGroups(from articles: [StudioArticle]) -> [NotebookContextSourceGroup] {
    let articles = articles
        .enumerated()
        .sorted { lhs, rhs in
            let lhsRank = notebookPoolTypeRank[lhs.element.sourceType] ?? Int.max
            let rhsRank = notebookPoolTypeRank[rhs.element.sourceType] ?? Int.max
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.offset < rhs.offset
        }
        .map(\.element)

    let bookSourcesByGroup = Dictionary(
        grouping: articles.filter { article in
            article.sourceType == .book
                && article.parentGroup?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        },
        by: { $0.parentGroup ?? "" }
    )
    var emittedBookGroups = Set<String>()
    var groups: [NotebookContextSourceGroup] = []

    for article in articles {
        guard article.sourceType == .book,
              let groupName = article.parentGroup?.trimmingCharacters(in: .whitespacesAndNewlines),
              !groupName.isEmpty else {
            groups.append(.source(article))
            continue
        }
        guard emittedBookGroups.insert(groupName).inserted else { continue }
        groups.append(.book(groupName: groupName, sources: notebookSortedBookChapters(bookSourcesByGroup[groupName] ?? [article])))
    }

    return groups
}

/// How a notebook's Sources list is ordered; this Mac's choice, as the Space
/// list's is (`SpaceSort`). By Type is the list as it was: the kinds in the
/// sidebar's order, A to Z within each. Every other order is one flat list,
/// the row's glyph saying the kind. A source with nothing to order by (no
/// year, no author, no length) goes last in either direction.
enum NotebookSourceSort: String, CaseIterable, Identifiable {
    case type
    case titleAscending, titleDescending, author
    case addedNewest, addedOldest
    case publishedNewest, publishedOldest
    case longest, shortest
    case inChat, readingStatus, studyOrder

    static let preferenceKey = "notebook.sources.sort"
    static let standard: NotebookSourceSort = .type

    var id: String { rawValue }

    var title: String {
        switch self {
        case .type: return "Type"
        case .titleAscending: return "Title A to Z"
        case .titleDescending: return "Title Z to A"
        case .author: return "Author"
        case .addedNewest: return "Recently Added"
        case .addedOldest: return "Oldest Added"
        case .publishedNewest: return "Newest Published"
        case .publishedOldest: return "Oldest Published"
        case .longest: return "Longest First"
        case .shortest: return "Shortest First"
        case .inChat: return "In Chat First"
        case .readingStatus: return "Reading Status"
        case .studyOrder: return "Study Order"
        }
    }

    /// The menu's groups, each a section of the menu under its heading.
    struct MenuGroup: Identifiable {
        let title: String
        let options: [NotebookSourceSort]
        var id: String { title }
    }

    static let menuGroups: [MenuGroup] = [
        MenuGroup(title: "Group", options: [.type]),
        MenuGroup(title: "Name", options: [.titleAscending, .titleDescending, .author]),
        MenuGroup(title: "Date", options: [.addedNewest, .addedOldest, .publishedNewest, .publishedOldest]),
        MenuGroup(title: "Length", options: [.longest, .shortest]),
        MenuGroup(title: "Progress", options: [.inChat, .readingStatus, .studyOrder]),
    ]
}

/// What `notebookSortedGroups` reads off the notebook that the sources
/// themselves do not hold.
struct NotebookSourceSortInputs {
    /// The notebook's items, for when each source joined it and its study order.
    var items: [LearningGoalItem]
    /// A book's name as the list shows it.
    var bookTitle: (String) -> String
    /// 0 to read, 1 reading, 2 understood.
    var statusRank: (String) -> Int
    /// Whether the notebook's chats read these sources.
    var chatState: ([String]) -> NotebookTickState
}

/// The Notebook's sources as one list in `sort`'s order, a book's chapters
/// kept under its one row. By Type is `notebookContextGroups`: the stored
/// study order within each kind. Ties fall to the title, then to that order.
func notebookSortedGroups(
    from articles: [StudioArticle],
    sort: NotebookSourceSort,
    inputs: NotebookSourceSortInputs
) -> [NotebookContextSourceGroup] {
    let groups = notebookContextGroups(from: articles)
    guard sort != .type else { return groups }

    let itemsBySource = Dictionary(
        inputs.items.map { ($0.sourceID, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    struct Keyed {
        let offset: Int
        let group: NotebookContextSourceGroup
        let title: String
        let sources: [StudioArticle]
    }
    let keyed = groups.enumerated().map { offset, group -> Keyed in
        switch group {
        case .source(let article):
            return Keyed(offset: offset, group: group, title: article.title, sources: [article])
        case .book(let groupName, let sources):
            return Keyed(offset: offset, group: group, title: inputs.bookTitle(groupName), sources: sources)
        }
    }

    func added(_ entry: Keyed, newest: Bool) -> Date? {
        let dates = entry.sources.compactMap { itemsBySource[$0.id]?.addedAt }
        return newest ? dates.max() : dates.min()
    }
    func year(_ entry: Keyed) -> Int? {
        entry.sources.lazy
            .compactMap { Int(($0.publishedYear ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) }
            .first
    }
    func author(_ entry: Keyed) -> String? {
        entry.sources.lazy
            .compactMap { $0.author?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
    func words(_ entry: Keyed) -> Int? {
        let counts = entry.sources.compactMap(\.wordCount)
        return counts.isEmpty ? nil : counts.reduce(0, +)
    }
    func order<T: Comparable>(_ lhs: T?, _ rhs: T?, descending: Bool) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case (let l?, let r?):
            if l == r { return .orderedSame }
            return (l < r) != descending ? .orderedAscending : .orderedDescending
        }
    }
    func orderText(_ lhs: String?, _ rhs: String?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case (let l?, let r?): return l.localizedStandardCompare(r)
        }
    }

    func primary(_ lhs: Keyed, _ rhs: Keyed) -> ComparisonResult {
        switch sort {
        case .type:
            return .orderedSame
        case .titleAscending:
            return lhs.title.localizedStandardCompare(rhs.title)
        case .titleDescending:
            return rhs.title.localizedStandardCompare(lhs.title)
        case .author:
            return orderText(author(lhs), author(rhs))
        case .addedNewest:
            return order(added(lhs, newest: true), added(rhs, newest: true), descending: true)
        case .addedOldest:
            return order(added(lhs, newest: false), added(rhs, newest: false), descending: false)
        case .publishedNewest:
            return order(year(lhs), year(rhs), descending: true)
        case .publishedOldest:
            return order(year(lhs), year(rhs), descending: false)
        case .longest:
            return order(words(lhs), words(rhs), descending: true)
        case .shortest:
            return order(words(lhs), words(rhs), descending: false)
        case .inChat:
            // Ticked, then some ticked, then unticked.
            func rank(_ entry: Keyed) -> Int {
                switch inputs.chatState(entry.sources.map(\.id)) {
                case .checked: return 0
                case .mixed: return 1
                case .unchecked: return 2
                }
            }
            return order(rank(lhs), rank(rhs), descending: false)
        case .readingStatus:
            // A book reads as its least-read chapter.
            func rank(_ entry: Keyed) -> Int {
                entry.sources.map { inputs.statusRank($0.id) }.min() ?? 0
            }
            return order(rank(lhs), rank(rhs), descending: false)
        case .studyOrder:
            func sequence(_ entry: Keyed) -> Double? {
                entry.sources.compactMap { itemsBySource[$0.id]?.sequence }.min()
            }
            let byOrder = order(sequence(lhs), sequence(rhs), descending: false)
            if byOrder != .orderedSame { return byOrder }
            // Unsequenced sources trail in the order they joined.
            return order(added(lhs, newest: false), added(rhs, newest: false), descending: false)
        }
    }

    return keyed
        .sorted { lhs, rhs in
            let byKey = primary(lhs, rhs)
            if byKey != .orderedSame { return byKey == .orderedAscending }
            let byTitle = lhs.title.localizedStandardCompare(rhs.title)
            if byTitle != .orderedSame { return byTitle == .orderedAscending }
            return lhs.offset < rhs.offset
        }
        .map(\.group)
}

func notebookSortedBookChapters(_ sources: [StudioArticle]) -> [StudioArticle] {
    sources.sorted {
        if let lhs = $0.courseSortIndex, let rhs = $1.courseSortIndex, lhs != rhs {
            return lhs < rhs
        }
        if $0.courseSortIndex != nil { return true }
        if $1.courseSortIndex != nil { return false }
        return $0.title.localizedStandardCompare($1.title) == .orderedAscending
    }
}

/// A book's chapters arrive as the flattened EPUB table of contents, so structural part
/// dividers ("Part 3 Insider Deal: …") sit in the same flat list as real chapters
/// ("7) Why Bacteria are Simple"). Telling the two apart lets the chapter list show a
/// number gutter and render dividers as section breaks instead of look-alike rows.
enum BookChapterTitle {
    /// Splits the leading chapter number out of a normalized title.
    /// `"7) Why Bacteria are Simple"` → `("7", "Why Bacteria are Simple")`.
    static func split(_ title: String) -> (number: String?, text: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let prefix = trimmed.range(of: #"^\d+\)\s+"#, options: .regularExpression),
              let digits = trimmed.range(of: #"^\d+"#, options: .regularExpression) else {
            return (nil, trimmed)
        }
        return (String(trimmed[digits]), String(trimmed[prefix.upperBound...]))
    }

    /// True for TOC entries that name a structural division rather than a chapter.
    /// These contentless nodes are kept out of the chapter list and the chapter count.
    static func isPartDivider(_ article: StudioArticle) -> Bool {
        article.title.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"^(part|section|book)\s+(\d+|[ivxlc]+)\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// "6 chapters" counting only real chapters — part dividers aren't chapters.
    static func countLabel(for sources: [StudioArticle]) -> String {
        let chapters = sources.filter { !isPartDivider($0) }.count
        guard chapters > 0 else {
            return "\(sources.count) section\(sources.count == 1 ? "" : "s")"
        }
        return "\(chapters) chapter\(chapters == 1 ? "" : "s")"
    }
}

/// Indents an expanded book's chapters under their group header and hangs a hairline
/// rail down the left so the chapters read as belonging to the book above them.
struct BookChapterStack<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        LazyVStack(spacing: 1) {
            content
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(width: 1)
        }
        .padding(.leading, 8)
    }
}
