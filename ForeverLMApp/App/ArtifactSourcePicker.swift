// The Docs source picker and its chapter screen.

import AppKit
import SwiftUI

/// One book on the Docs source picker's chapter screen. Flat by design, for the
/// same reason `ArtifactSourcePickerRow` is: the picker's `List` only ever needs
/// the strings a row draws.
private struct ArtifactSourcePickerChapter: Identifiable, Equatable {
    let id: String
    let title: String
}

private struct ArtifactSourcePickerBook: Identifiable, Equatable {
    let id: String
    let title: String
    let chapters: [ArtifactSourcePickerChapter]
}

/// The highlighted passage, read as a first guess at what to search for.
enum ArtifactSourceSeedQuery {
    /// The words the writer highlighted, when they are short enough to work as a
    /// query. The picker matches titles, authors and domains — so a phrase stands
    /// a chance of naming a source and a paragraph never does. Anything longer
    /// than a phrase opens the picker unfiltered rather than on an empty list.
    static func from(_ selectedText: String) -> String {
        let collapsed = selectedText
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: Self.edgePunctuation)
        guard !trimmed.isEmpty,
              trimmed.count <= 60,
              trimmed.split(separator: " ").count <= 8 else { return "" }
        return trimmed
    }

    /// Sentence punctuation the highlight drags along at either end. Dropped so
    /// "…fluorescence." searches for the word rather than the word plus a stop.
    private static let edgePunctuation = CharacterSet(charactersIn: " .,;:!?…\"'“”‘’")
}

struct ArtifactSourcePicker: View {
    /// What the chosen sources are for. The list and the search are the same;
    /// only the words at the bottom change, because "stands on" is a claim about
    /// a passage and makes no sense when the sources are joining a chat.
    enum Purpose {
        /// Grounding a Docs passage: the sources it stands on.
        case grounding
        /// Adding sources to the chat's context, from `/source` in the composer.
        case chat
        /// Writing sources into a Page as cards, from its `/` and `@` Sources rows.
        case insert

        var emptyStatus: String {
            switch self {
            case .grounding: return "No sources linked to this passage yet"
            case .chat, .insert: return "Nothing chosen yet"
            }
        }

        func status(count: Int) -> LocalizedStringKey {
            switch self {
            case .grounding: return "^[\(count) source](inflect: true) attached"
            case .chat, .insert: return "^[\(count) source](inflect: true) chosen"
            }
        }

        var clearTitle: String {
            switch self {
            case .grounding: return "Detach all"
            case .chat, .insert: return "Clear"
            }
        }

        var commitTitle: String {
            switch self {
            case .grounding: return "Done"
            case .chat: return "Add to Chat"
            case .insert: return "Insert"
            }
        }
    }

    /// Choosing here answers "what does this passage stand on" — usually more
    /// than one source, and an edit to an answer that already exists — so the
    /// picker collects a set and commits once rather than closing on a click.
    let initial: [String]
    let purpose: Purpose
    let commit: ([String]) -> Void

    /// The passage's own words, prefilled into the search field. Focusing selects
    /// them, so typing replaces the guess instead of having to clear it first.
    init(
        initial: [String],
        seed: String,
        purpose: Purpose = .grounding,
        commit: @escaping ([String]) -> Void
    ) {
        self.initial = initial
        self.purpose = purpose
        self.commit = commit
        let seeded = ArtifactSourceSeedQuery.from(seed)
        _search = State(initialValue: seeded)
        _seededQuery = State(initialValue: seeded)
    }

    @Environment(StudioViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    @State private var search: String
    /// The seed still standing unedited in the field, kept so a guess that names
    /// nothing can be taken back exactly once.
    @State private var seededQuery: String
    @State private var rows: [ArtifactSourcePickerRow] = []
    /// The library analysed for search, built once per opening. Held as a task so
    /// a keystroke that lands while it is being built waits for that build rather
    /// than starting another.
    @State private var libraryIndex: Task<ArtifactSourcePickerIndex, Never>?
    @State private var sourceTypeFilter: ArtifactSourcePickerFilter = .all
    @State private var attached: [String] = []
    @State private var didLoadAttached = false
    /// The book whose chapters are on screen. A passage rarely stands on a whole
    /// book, so choosing one asks which chapter rather than committing the shelf.
    @State private var drilledBook: ArtifactSourcePickerBook?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if let book = drilledBook {
                chapterList(for: book)
            } else {
                sourceList
            }

            Divider()
            footer
        }
        .frame(minWidth: 440, minHeight: 480)
        .task(id: search) { await refreshRows() }
        .onAppear {
            searchFocused = true
            guard !didLoadAttached else { return }
            didLoadAttached = true
            attached = initial
        }
        .onExitCommand {
            // Escape backs out of a book before it closes the picker, so a
            // wrong turn costs one keystroke rather than the whole selection.
            if drilledBook != nil {
                drilledBook = nil
            } else {
                dismiss()
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            if let book = drilledBook {
                Button {
                    drilledBook = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.hoverWash(inset: -3))
                .help("All sources")
                Text(book.title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            } else {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search sources", text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                sourceTypeMenu
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.hoverWash(in: Circle(), inset: -3))
            .help("Close")
        }
        .padding(12)
    }

    private var sourceTypeMenu: some View {
        Menu {
            ForEach(ArtifactSourcePickerFilter.allCases) { filter in
                Button {
                    sourceTypeFilter = filter
                    searchFocused = true
                } label: {
                    if sourceTypeFilter == filter {
                        Label(filter.title, systemImage: "checkmark")
                    } else {
                        Text(filter.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                if sourceTypeFilter != .all {
                    Text(sourceTypeFilter.activeTitle)
                        .lineLimit(1)
                }
            }
            .zoomedSystemFont(size: 10, weight: sourceTypeFilter == .all ? .regular : .medium)
            .foregroundStyle(sourceTypeFilter == .all ? Color.secondary : Color.accentColor)
            .padding(.horizontal, sourceTypeFilter == .all ? 2 : 7)
            .padding(.vertical, 4)
            .background(
                sourceTypeFilter == .all ? Color.clear : Color.accentColor.opacity(0.12),
                in: Capsule()
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(sourceTypeFilter == .all ? "Filter source type" : "Showing \(sourceTypeFilter.title.lowercased())")
        .accessibilityLabel("Filter source type")
        .accessibilityValue(sourceTypeFilter.title)
    }

    /// A lazy stack, not a `List`. On the Mac a `List` is an outline view, and when
    /// its rows change it measures every row it holds: a keystroke that took the
    /// library's ~4,500 rows down to a handful wedged the main thread for two to
    /// four seconds (the product owner's stall samples, 2026-10-07, all in
    /// `OutlineListCoordinator.diffRows` asking each row whether it is a group
    /// row). A lazy stack builds only the rows on screen.
    private var sourceList: some View {
        let shown = filteredRows
        let firstID = shown.first?.id
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Color.clear
                        .frame(height: 0)
                        .id(Self.sourceListTop)
                    ForEach(shown) { row in
                        if row.id != firstID {
                            // Under the text, as an inset list draws it.
                            Divider()
                                .padding(.leading, 51)
                        }
                        sourceRow(row)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            // New results start at the top, as a list's did.
            .onChange(of: search) { proxy.scrollTo(Self.sourceListTop, anchor: .top) }
            .onChange(of: sourceTypeFilter) { proxy.scrollTo(Self.sourceListTop, anchor: .top) }
        }
    }

    private static let sourceListTop = "source-list-top"

    private func sourceRow(_ row: ArtifactSourcePickerRow) -> some View {
        Button {
            select(row)
        } label: {
            HStack(spacing: 9) {
                // Looked up here rather than carried in the row: the thumbnail is
                // the only thing that wants the whole source, and only rows the
                // list actually draws reach this point.
                if let source = vm.articlesById[row.sourceID] {
                    SourceThumbnail(
                        source: source,
                        size: 34,
                        bookCoverPath: row.bookID.flatMap { vm.bookCoverPaths[$0] }
                    )
                } else {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(.quaternary)
                        .frame(width: 34, height: 34)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .lineLimit(1)
                    Text(row.subtitle)
                        .zoomedSystemFont(size: 9)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let bookID = row.bookID {
                    bookIndicator(for: bookID)
                } else {
                    attachmentMark(isAttached: attached.contains(row.sourceID))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        // The wash fills the row and stops there, so it never covers the
        // dividers either side.
        .buttonStyle(.hoverWash(inset: 0))
    }

    private var filteredRows: [ArtifactSourcePickerRow] {
        rows.filter { sourceTypeFilter.includes(sourceType: $0.sourceType) }
    }

    private func chapterList(for book: ArtifactSourcePickerBook) -> some View {
        List {
            Button {
                attachWholeBook(book)
            } label: {
                chapterRow(
                    title: "Whole book",
                    subtitle: "^[\(book.chapters.count) chapter](inflect: true)",
                    isAttached: attached.contains(Self.bookToken(book.id))
                )
            }
            .buttonStyle(.hoverWash)

            ForEach(book.chapters) { chapter in
                Button {
                    attachChapter(chapter, of: book)
                } label: {
                    chapterRow(
                        title: chapter.title,
                        subtitle: nil,
                        isAttached: attached.contains(chapter.id)
                    )
                }
                .buttonStyle(.hoverWash)
            }
        }
        .listStyle(.inset)
    }

    private func chapterRow(
        title: String,
        subtitle: LocalizedStringKey?,
        isAttached: Bool
    ) -> some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .zoomedSystemFont(size: 9)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            attachmentMark(isAttached: isAttached)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Group {
                if attached.isEmpty {
                    Text(purpose.emptyStatus)
                } else {
                    Text(purpose.status(count: attached.count))
                }
            }
            .zoomedSystemFont(size: 11)
            .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            // Detaching is the same gesture as attaching nothing, so it
            // belongs here rather than behind a second control.
            if !attached.isEmpty {
                Button(purpose.clearTitle) { attached = [] }
                    .buttonStyle(.hoverWash)
                    .foregroundStyle(.secondary)
            }
            Button(purpose.commitTitle) {
                commit(attached)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func attachmentMark(isAttached: Bool) -> some View {
        Image(systemName: isAttached ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(isAttached ? Color.accentColor : Color.secondary.opacity(0.5))
    }

    /// What a book row reports: the whole book, a count of the chapters chosen
    /// inside it, or nothing — always beside the chevron that leads to them.
    @ViewBuilder
    private func bookIndicator(for bookID: String) -> some View {
        HStack(spacing: 6) {
            if attached.contains(Self.bookToken(bookID)) {
                attachmentMark(isAttached: true)
            } else if let count = attachedChapterCountByBook[bookID], count > 0 {
                Text("\(count)")
                    .zoomedSystemFont(size: 10, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
            }
            Image(systemName: "chevron.right")
                .zoomedSystemFont(size: 10)
                .foregroundStyle(.tertiary)
        }
    }

    /// How many chapters of each book are attached on their own. Cheap because it
    /// walks what is attached rather than the library: a chapter token is an
    /// ordinary source id, and its book is the source's own group.
    private var attachedChapterCountByBook: [String: Int] {
        var counts: [String: Int] = [:]
        for token in attached where !token.hasPrefix(StudioViewModel.notepadGroundingBookPrefix) {
            guard let source = vm.articlesById[token],
                  source.sourceType == .book,
                  let bookID = source.parentGroup?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !bookID.isEmpty else { continue }
            counts[bookID, default: 0] += 1
        }
        return counts
    }

    /// What a whole book is attached as. The same reference `notepadGroundingBookPrefix`
    /// names for a book row, spelled out here because the picker asks for it by
    /// book id rather than by the chapter that happens to represent it.
    private static func bookToken(_ bookID: String) -> String {
        StudioViewModel.notepadGroundingBookPrefix + bookID
    }

    /// A book row opens its chapters; every other row attaches itself.
    private func select(_ row: ArtifactSourcePickerRow) {
        guard let bookID = row.bookID else {
            toggle(row.sourceID)
            return
        }
        let chapters = vm.bookChapterArticlesInOrder(for: bookID)
            .map { ArtifactSourcePickerChapter(id: $0.id, title: $0.title) }
        guard !chapters.isEmpty else {
            toggle(Self.bookToken(bookID))
            return
        }
        drilledBook = ArtifactSourcePickerBook(id: bookID, title: row.title, chapters: chapters)
    }

    /// The whole book and a hand-picked chapter answer the same question, so
    /// choosing one clears the other rather than stacking both onto the passage.
    private func attachWholeBook(_ book: ArtifactSourcePickerBook) {
        let chapterIDs = Set(book.chapters.map(\.id))
        attached.removeAll { chapterIDs.contains($0) }
        toggle(Self.bookToken(book.id))
    }

    private func attachChapter(_ chapter: ArtifactSourcePickerChapter, of book: ArtifactSourcePickerBook) {
        attached.removeAll { $0 == Self.bookToken(book.id) }
        toggle(chapter.id)
    }

    private func toggle(_ reference: String) {
        if let index = attached.firstIndex(of: reference) {
            attached.remove(at: index)
        } else {
            attached.append(reference)
        }
    }

    /// Rows come from a task, not a computed property.
    ///
    /// Read during `body`, this rebuilt the entire library on every body pass —
    /// and presenting a sheet triggers several while AppKit sizes the window, all
    /// of it on the main thread before anything could draw. Now the library is
    /// analysed once per opening (`ArtifactSourcePickerIndex`) and a keystroke is a
    /// few milliseconds of comparing, off the main actor.
    private func refreshRows() async {
        let query = search
        let index = await analysedLibrary()
        guard !Task.isCancelled else { return }
        var matched = await Task.detached(priority: .userInitiated) {
            index.rows(matching: query)
        }.value
        guard !Task.isCancelled else { return }
        rows = matched

        // The titles answer every keystroke; the words inside a source's own text
        // answer once typing pauses, from the same indexed pass the sidebar's
        // search runs, and join the list. "direct data" names no title, but it is
        // in the page that says it.
        if !query.isEmpty {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let contentIDs = await vm.storage.strictSourceContentMatchIDs(queryText: query, limit: 300)
            guard !Task.isCancelled else { return }
            if !contentIDs.isEmpty {
                let withContent = await Task.detached(priority: .userInitiated) {
                    index.rows(matching: query, contentMatchIDs: contentIDs)
                }.value
                guard !Task.isCancelled else { return }
                if withContent.count != matched.count {
                    matched = withContent
                    rows = matched
                }
            }
        }

        // The seed is a guess the writer never typed. When it matches nothing,
        // hand back the whole library rather than an empty list they have to
        // clear a field to escape — but only while the guess stands untouched,
        // so a search they typed themselves is allowed to find nothing.
        if matched.isEmpty, !seededQuery.isEmpty, query == seededQuery {
            seededQuery = ""
            search = ""
        }
    }

    private func analysedLibrary() async -> ArtifactSourcePickerIndex {
        if let libraryIndex { return await libraryIndex.value }
        let build = Task { await vm.artifactSourcePickerIndex() }
        libraryIndex = build
        return await build.value
    }
}
