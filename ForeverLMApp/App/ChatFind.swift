// Find in chat and the jump-to-latest button.

import SwiftUI

// MARK: - Find in chat

/// Find in the open chat (⌘F, then Return or ⌘G for the next match and ⇧Return
/// or ⌘⇧G for the previous), as Codex finds in a thread. A match is a turn of
/// the transcript (`ReviewChatTranscriptBlock`) whose words hold the query;
/// the transcript scrolls it to the middle and marks it. The first search
/// lands on the newest match, where the learner already is.
@MainActor
@Observable
final class ChatFind {
    var isVisible = false
    var query = ""
    private(set) var matchIDs: [UUID] = []
    private(set) var currentIndex: Int?
    private(set) var searchedQuery = ""
    private(set) var focusRevision = 0
    /// Bumped by every step; the transcript scrolls to `currentMatchID` on it.
    private(set) var scrollRevision = 0

    var currentMatchID: UUID? {
        guard let currentIndex, matchIDs.indices.contains(currentIndex) else { return nil }
        return matchIDs[currentIndex]
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "2 of 7", "No matches", or nothing before the first search of this query.
    var status: String {
        guard !searchedQuery.isEmpty, searchedQuery == trimmedQuery else { return "" }
        guard let currentIndex, !matchIDs.isEmpty else { return "No matches" }
        return "\(currentIndex + 1) of \(matchIDs.count)"
    }

    func show() {
        isVisible = true
        focusRevision += 1
    }

    func close() {
        isVisible = false
        query = ""
        matchIDs = []
        currentIndex = nil
        searchedQuery = ""
    }

    /// The next match after the current one (or the one before it), read
    /// afresh from `blocks` so turns that arrived since are found too. A new
    /// query starts from the newest match.
    func step(in blocks: [ReviewChatTranscriptBlock], backwards: Bool = false) {
        let query = trimmedQuery
        defer { scrollRevision += 1 }
        guard !query.isEmpty else {
            matchIDs = []
            currentIndex = nil
            searchedQuery = ""
            return
        }
        let fresh = Self.matchingBlockIDs(query, in: blocks)
        let previous = query == searchedQuery ? currentMatchID : nil
        searchedQuery = query
        matchIDs = fresh
        guard !fresh.isEmpty else {
            currentIndex = nil
            return
        }
        if let previous, let at = fresh.firstIndex(of: previous) {
            currentIndex = backwards ? (at - 1 + fresh.count) % fresh.count : (at + 1) % fresh.count
        } else {
            currentIndex = fresh.count - 1
        }
    }

    /// The turns whose words, the learner's or the reply's, hold `query`,
    /// ignoring case and accents, oldest first. Tool rows are not searched.
    static func matchingBlockIDs(_ query: String, in blocks: [ReviewChatTranscriptBlock]) -> [UUID] {
        blocks.filter { block in
            ([block.userMessage].compactMap { $0 } + block.answerMessages).contains { message in
                guard message.toolActivity == nil, message.role != .tool,
                      let text = ReviewSessionManager.displayableMessageContent(role: message.role, content: message.content)
                else { return false }
                return AttachedImageReference.split(text).text.localizedStandardContains(query)
            }
        }
        .map(\.id)
    }
}

/// The find bar over the top of the transcript, quiet like the Reader's: the
/// field, where it is ("2 of 7"), previous and next, and ×. Escape closes it.
struct ChatFindBar: View {
    @Bindable var find: ChatFind
    /// The transcript's turns, read when a search runs.
    let blocks: () -> [ReviewChatTranscriptBlock]
    @FocusState private var isFocused: Bool

    private var hasQuery: Bool {
        !find.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .zoomedSystemFont(size: 11)
                .foregroundStyle(.secondary)
            TextField("Find in chat", text: $find.query)
                .textFieldStyle(.plain)
                .zoomedSystemFont(size: 12)
                .focused($isFocused)
                .onSubmit { step(backwards: NSEvent.modifierFlags.contains(.shift)) }
                .accessibilityIdentifier("mac.chatFind.field")
            if !find.status.isEmpty {
                Text(find.status)
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            button("chevron.up", help: "Previous match (⌘⇧G)") { step(backwards: true) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!hasQuery)
            button("chevron.down", help: "Next match (⌘G)") { step(backwards: false) }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(!hasQuery)
            button("xmark", help: "Close find") { find.close() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .frame(maxWidth: 420)
        .onAppear { isFocused = true }
        .onChange(of: find.focusRevision) { _, _ in isFocused = true }
        .onExitCommand { find.close() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mac.chatFind")
    }

    private func step(backwards: Bool) {
        find.step(in: blocks(), backwards: backwards)
    }

    private func button(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .zoomedSystemFont(size: 10, weight: .semibold)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 5))
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Jump to latest

/// The arrow over the foot of the transcript once it is scrolled up from the
/// newest turn, as Codex's: a click goes back down.
enum ChatJumpToLatest {
    /// How far above the end, beyond the empty band kept under the last row,
    /// the view must be before the arrow shows.
    static let threshold: CGFloat = 120

    static func isScrolledUp(offsetY: CGFloat, visibleHeight: CGFloat, contentHeight: CGFloat, bottomReserve: CGFloat) -> Bool {
        contentHeight - (offsetY + visibleHeight) > bottomReserve + threshold
    }
}

/// Reports whether the scroll view it modifies is scrolled up from its end
/// (`ChatJumpToLatest`). macOS 15 reads scroll geometry; on 14 it reports
/// nothing and the arrow never shows.
struct ChatScrolledUpReader: ViewModifier {
    let bottomReserve: CGFloat
    @Binding var isScrolledUp: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                ChatJumpToLatest.isScrolledUp(
                    offsetY: geometry.contentOffset.y,
                    visibleHeight: geometry.containerSize.height,
                    contentHeight: geometry.contentSize.height,
                    bottomReserve: bottomReserve
                )
            } action: { _, scrolledUp in
                if isScrolledUp != scrolledUp { isScrolledUp = scrolledUp }
            }
        } else {
            content
        }
    }
}

struct ChatJumpToLatestButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .zoomedSystemFont(size: 12, weight: .semibold)
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.10)))
                .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Jump to latest")
        .accessibilityLabel("Jump to latest")
        .accessibilityIdentifier("mac.chatJumpToLatest")
    }
}

/// The turn Find in chat is on: a faint wash behind it.
struct ChatFindMatchMark: ViewModifier {
    let isMatch: Bool

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(isMatch ? 0.09 : 0))
                .padding(-6)
                .allowsHitTesting(false)
        )
    }
}
