import SwiftUI

/// The Memory pane's **Sources** (docs/memory-design.md, "Cards for every
/// source"): every source in the library with how many cards it has, and a
/// verdict on each. **Make Cards** opens the Make Cards sheet for it (and, once
/// it has cards, **Make More Cards**); **Not Worth Keeping** removes it as the
/// Sources list's Remove does, with the same Undo banner. The goal is at least
/// one card for each piece of content in the library, and every piece worth its
/// weight (product owner, 2026-10-16: "go through ALL the sources in my
/// library and come up with at least one flashcard; and then the option to
/// generate more").
///
/// No Cards, the list it opens on, holds what still waits for a verdict; All
/// holds the whole library, for the more. The pane's scope narrows both to a
/// notebook's sources. Opening it writes nothing; its read runs off the main
/// actor and happens again when cards change or the library does.
struct MemorySourcesView: View {
    let scope: MemoryReviewScope

    @Environment(StudioViewModel.self) private var vm

    @State private var coverage = SourceCardCoverage()
    @State private var hasLoaded = false
    @State private var loadError: String?
    @State private var listScope: SourceCardScope = .withoutCards
    @State private var query = ""

    /// How many sources the head's Make Cards takes together: what one Auto
    /// request can give four cards each (`MemoryCardRequestCount`).
    static let batchSize = MemoryCardRequestCount.maximumPerRequest / MemoryCardRequestCount.autoPerSource

    private static let columnMaxWidth: CGFloat = 680

    private var scopeTag: String {
        switch scope {
        case .allNotebooks: return "all"
        case .notebook(let id): return id
        }
    }

    private var loadKey: String {
        "\(scopeTag)#\(vm.memoryCardRevision)#\(vm.articles.count)"
    }

    /// The notebook's sources while the pane is narrowed to one; nil is all.
    private var allowedSourceIDs: Set<String>? {
        vm.memoryCardScope(for: scope)?.sourceIDs
    }

    /// Sources a removal has taken out of the list, from the click on.
    private var removingIDs: Set<String> {
        vm.pendingDeletionSourceIDs.values.reduce(into: vm.sourceIDsBeingRemoved) { $0.formUnion($1) }
    }

    var body: some View {
        let removing = removingIDs
        let allowed = allowedSourceIDs
        let inScope = SourceCardList.filter(coverage.rows, scope: .all, allowed: allowed, removed: removing)
        let rows = SourceCardList.filter(inScope, scope: listScope, query: query)
        let withoutCards = inScope.filter { $0.state == .none }.count
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                head(withoutCards: withoutCards, all: inScope.count, batch: listScope == .withoutCards ? rows : [])
                    .padding(.bottom, 10)
                if rows.isEmpty {
                    emptyLine(isFiltered: !query.isEmpty, hasAny: !inScope.isEmpty)
                        .padding(.top, SpacePlaceMetrics.emptyTopPadding)
                        .frame(maxWidth: .infinity)
                }
                ForEach(rows) { row in
                    MemorySourceRow(row: row) {
                        make(row)
                    } notWorthKeeping: {
                        Task { await vm.removeArticle(id: row.id) }
                    }
                }
            }
            .frame(maxWidth: Self.columnMaxWidth, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .task(id: loadKey) { await load() }
        .accessibilityIdentifier("memory.pane.sources")
    }

    // MARK: Head

    /// The two lists as the Space's pills, the search, and Make Cards for the
    /// first ten still waiting.
    private func head(withoutCards: Int, all: Int, batch: [SourceCardRow]) -> some View {
        HStack(spacing: 4) {
            ForEach(SourceCardScope.allCases) { item in
                SpaceScopePill(
                    title: item.title,
                    isSelected: listScope == item,
                    count: hasLoaded ? (item == .withoutCards ? withoutCards : all) : nil
                ) {
                    if listScope != item { listScope = item }
                }
                .accessibilityIdentifier("memory.pane.sources.\(item.rawValue)")
            }
            Spacer(minLength: 8)
            SpaceSearchField(text: $query, prompt: "Search by title", identifier: "memory.pane.sources.search")
                .frame(width: SpacePlaceMetrics.searchWidth)
            if batch.count > 1 {
                let ids = Array(batch.prefix(Self.batchSize).map(\.id))
                SpaceDarkPillButton(title: "Make Cards for \(ids.count)", systemImage: nil, image: nil) {
                    vm.presentMakeCards(notebookID: notebookID, sourceIDs: ids)
                }
                .accessibilityIdentifier("memory.pane.sources.makeBatch")
            }
        }
    }

    private func emptyLine(isFiltered: Bool, hasAny: Bool) -> some View {
        Group {
            if !hasLoaded {
                Text(" ")
            } else if let loadError {
                SpaceEmptyLine(systemImage: "exclamationmark.triangle", text: loadError)
            } else if isFiltered {
                SpaceEmptyLine(systemImage: "magnifyingglass", text: "No source matches")
            } else if listScope == .withoutCards, hasAny {
                SpaceEmptyLine(systemImage: "checkmark.circle", text: "Every source has cards")
            } else {
                SpaceEmptyLine(systemImage: "books.vertical", text: "No sources")
            }
        }
    }

    // MARK: Actions

    /// The notebook the cards are made in while the pane is narrowed to one.
    private var notebookID: String? {
        if case .notebook(let id) = scope { return id }
        return nil
    }

    private func make(_ row: SourceCardRow) {
        vm.presentMakeCards(notebookID: notebookID, sourceIDs: [row.id])
    }

    private func load() async {
        do {
            let read = try await vm.storage.sourceCardCoverage()
            guard !Task.isCancelled else { return }
            if read != coverage { coverage = read }
            loadError = nil
        } catch {
            guard !Task.isCancelled else { return }
            loadError = "The sources could not be read. \(error.localizedDescription)"
        }
        hasLoaded = true
    }
}

/// One source: its kind, its title, and how many cards it has; under the
/// pointer, its two verdicts.
private struct MemorySourceRow: View {
    let row: SourceCardRow
    let makeCards: () -> Void
    let notWorthKeeping: () -> Void

    @Environment(StudioViewModel.self) private var vm
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: row.sourceType.symbolName)
                .zoomedSystemFont(size: 12.5)
                .foregroundStyle(.tertiary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(row.title)
                .zoomedSystemFont(size: 14)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if isHovering {
                HStack(spacing: 2) {
                    verdict("Not Worth Keeping", identifier: "not-worth-keeping", action: notWorthKeeping)
                    verdict(row.state.makeCardsTitle, identifier: "make-cards", action: makeCards)
                }
            } else if let label = row.state.label {
                Text(label)
                    .zoomedSystemFont(size: 12)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .textSelection(.disabled)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .frame(minHeight: 38)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.05 : 0))
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(row.state.makeCardsTitle, action: makeCards)
            Button("Not Worth Keeping", role: .destructive, action: notWorthKeeping)
            Divider()
            Button("Open Source") {
                Task { await vm.openLinkedSourceInReader(row.id, beside: .memory) }
            }
            OtherWindowSourceMenuItem(sourceID: row.id)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.title)
        .accessibilityIdentifier("memory.pane.sources.row.\(row.id)")
    }

    private func verdict(_ title: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .zoomedSystemFont(size: 12.5, weight: .medium)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .contentShape(Capsule())
        }
        .buttonStyle(.hoverWash(in: Capsule(), inset: 0, opacity: 0.08))
        .accessibilityIdentifier("memory.pane.sources.\(identifier).\(row.id)")
    }
}
