import SwiftUI

/// The heading of a notebook chat's empty state, above the composer: the
/// notebook's emoji or cover, its name, and the description stored on it,
/// which is the notebook's own words rather than helper copy. What the guide
/// offers stands under the composer (`NotebookChatGuide`), as ChatGPT's
/// project page lists its chats under its composer (2026-10-06).
struct NotebookChatGuideHeading: View {
    /// The notebook's emoji (`NotebookTitle.displayIcon`), which its cover
    /// replaces once the Mac holds one, and its name without it.
    let notebookID: String
    let icon: String
    let title: String
    /// The notebook's stored description; nil when it has none.
    let summary: String?
    var columnWidth: CGFloat = 420

    var body: some View {
        VStack(spacing: StudioDesign.Spacing.small) {
            NotebookIconView(notebookID: notebookID, size: 44, cornerRadius: 10) {
                Text(icon)
                    .font(.system(size: 34))
            }
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 24, weight: .medium, design: .serif))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let summary {
                Text(summary)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: columnWidth)
        .frame(maxWidth: .infinity)
    }
}

/// The empty state of a notebook's chat, in the notebook workspace, under
/// the composer: the notebook's guide (docs/notebooks-design.md, "The
/// notebook guide"). Only when it has sources, a row of chips that ask for
/// something; an empty one offers nothing here, since the notebook's ⋯ and
/// the Notebook menu (⇧⌘I) add sources, and its Sources column suggests them
/// (product owner, 2026-10-12: "get rid of this add sources button"). How
/// many sources the chat reads is the Sources column's Select all row,
/// beside it ("N of M in chat" while not every source is ticked), and is
/// not said twice. Nothing here calls a
/// model: questions are suggested when asked for, once for the notebook's
/// sources: the questions an answer suggested are kept with the notebook and
/// offered here as cards until each is asked (`NotebookSuggestedQuestions`),
/// and Suggest questions comes back only when the sources change. Under them,
/// the notebook's latest chats, each one click from coming back: the full
/// rail listed them under the notebook's folder, and a notebook window's rail
/// is an icon strip. When it has more, **All chats** opens every one in a
/// popover with a search field (product owner, 2026-10-03: "where in foreverlm can
/// i easily see all the chats for a given notebook?").
struct NotebookChatGuide: View {
    /// One of the notebook's chats, as the guide lists it.
    struct RecentChat: Identifiable, Equatable {
        let id: String
        let title: String
        let date: Date
    }

    /// The ticked sources a chat reads, and all it could: what the chips
    /// are offered and enabled by.
    let inChat: Int
    let total: Int
    var columnWidth: CGFloat = 420
    /// The notebook's chats, newest first; empty for a notebook with none.
    /// The guide lists the first `recentChatLimit`, and All chats every one.
    var chats: [RecentChat] = []
    /// The kept questions, or the chip that asks for them
    /// (`StudioViewModel.notebookQuestionOffer`).
    var questions: NotebookSuggestedQuestions.Offer = .suggest
    let suggestQuestions: () -> Void
    /// Asks one of the kept questions in this chat.
    var askQuestion: (String) -> Void = { _ in }
    let review: () -> Void
    var openChat: (String) -> Void = { _ in }
    @State private var isListingAllChats = false

    /// How many of its chats the guide lists.
    static let recentChatLimit = 4

    /// The chats whose titles hold `query`, ignoring case and accents, in
    /// their order; all of them for an empty query.
    static func chats(_ chats: [RecentChat], matching query: String) -> [RecentChat] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return chats }
        return chats.filter { $0.title.localizedStandardContains(query) }
    }

    /// What the Suggest questions chip sends, as the learner's message.
    static let suggestQuestionsPrompt = "Suggest three questions I could ask about this notebook's sources."

    var body: some View {
        VStack(spacing: StudioDesign.Spacing.large) {
            if total > 0 {
                HStack(spacing: 8) {
                    if questions == .suggest {
                        chip("Suggest questions", systemImage: "sparkles", identifier: "notebook.guide.suggestQuestions", action: suggestQuestions)
                            .disabled(inChat == 0)
                    }
                    chip("Quiz me on it", systemImage: "graduationcap", identifier: "notebook.guide.review", action: review)
                        .disabled(inChat == 0)
                }
                if case .questions(let kept) = questions {
                    ChatSuggestedQuestionCards(
                        questions: kept,
                        fontSize: 13,
                        maxWidth: min(columnWidth, 560),
                        send: askQuestion
                    )
                    .disabled(inChat == 0)
                    .accessibilityIdentifier("notebook.guide.questions")
                }
            }

            if !chats.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(chats.prefix(Self.recentChatLimit)) { chat in
                        NotebookChatRow(chat: chat) { openChat(chat.id) }
                    }
                    if chats.count > Self.recentChatLimit {
                        allChatsButton
                    }
                }
                .frame(maxWidth: min(columnWidth, 420))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Chats in this notebook")
                .accessibilityIdentifier("notebook.guide.recentChats")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func chip(
        _ title: String,
        systemImage: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.04), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.hoverWash(in: Capsule()))
        .accessibilityIdentifier(identifier)
    }

    /// The row under the latest chats that lists every one: the iPhone
    /// guide's All chats, with the count where a chat's date stands.
    private var allChatsButton: some View {
        Button { isListingAllChats = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: NotebookChatRow.iconWidth)
                    .accessibilityHidden(true)
                Text("All chats")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("\(chats.count)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 8, inset: 0))
        .accessibilityLabel("All \(chats.count) chats")
        .accessibilityIdentifier("notebook.guide.allChats")
        .popover(isPresented: $isListingAllChats, arrowEdge: .bottom) {
            NotebookAllChatsPopover(chats: chats) { sessionID in
                isListingAllChats = false
                openChat(sessionID)
            }
        }
    }
}

/// One of the notebook's chats, in the guide and in its All chats popover:
/// a click opens it in this window, and its right-click in the other.
private struct NotebookChatRow: View {
    static let iconWidth: CGFloat = 16

    let chat: NotebookChatGuide.RecentChat
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.iconWidth)
                    .accessibilityHidden(true)
                Text(chat.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if ScreenRecordMode.showsDateStamp(chat.date) {
                    Text(chat.date, format: .relative(presentation: .named))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 8, inset: 0))
        .accessibilityLabel("Open chat \(chat.title)")
        .contextMenu {
            OtherWindowMenuItem(.chat(chat.id))
        }
    }
}

/// Every chat in the notebook, newest first, under a search field that
/// narrows them by title; Return opens the first that matches.
private struct NotebookAllChatsPopover: View {
    let chats: [NotebookChatGuide.RecentChat]
    let openChat: (String) -> Void
    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let matches = NotebookChatGuide.chats(chats, matching: query)
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search chats", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($isSearchFocused)
                .onSubmit {
                    if let first = matches.first { openChat(first.id) }
                }
                .padding(StudioDesign.Spacing.medium)
                .accessibilityIdentifier("notebook.guide.allChats.search")

            Divider()

            if matches.isEmpty {
                Text("No chat matches")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, StudioDesign.Spacing.large)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(matches) { chat in
                            NotebookChatRow(chat: chat) { openChat(chat.id) }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 420)
            }
        }
        .frame(width: 400)
        .onAppear { isSearchFocused = true }
        // A group of its own, so the identifier lands on the list and not on
        // the search field or the scroll area (DirectionsPopover).
        .accessibilityElement(children: .contain)
        .accessibilityLabel("All chats in this notebook")
        .accessibilityIdentifier("notebook.guide.allChats.list")
    }
}
