import SwiftUI

/// Which threads the Comments panel lists, as Codex's filter offers them
/// (`artifactComments.filterOpen` / `filterResolved`).
enum PageCommentFilter: String, CaseIterable, Identifiable {
    case open
    case resolved

    var id: String { rawValue }
    var title: String { self == .open ? "Open" : "Resolved" }
}

/// A page's Comments panel, beside the page as Codex draws it
/// (`codex.space.page.comments.*`, docs/docs-design.md "Comments"): one card a
/// thread, the passage it is on, its messages, Reply…, and each message's Edit
/// and Delete; Resolve and Reopen on the thread; Open and Resolved threads apart.
/// Choosing a thread marks its passage in the page and shows it, and clicking
/// marked words in the page opens the thread here (`selectedThreadID`, both
/// ways). The chats the page's passages started are the panel's second
/// section, ForeverLM's addition.
struct PageCommentsSidebar: View {
    @Environment(StudioViewModel.self) private var vm

    let artifactID: String
    @Binding var comments: [ArtifactCommentRecord]
    @Binding var chatLinks: [ArtifactChatLink]
    /// The passage a new comment is being written on, from the selection
    /// bar's Comment; nil while no comment is being started.
    @Binding var pendingSelection: ArtifactEditorSelection?
    /// The thread open here, whose passage the page marks and shows.
    @Binding var selectedThreadID: String?
    /// Threads whose words are no longer in the page.
    let detachedThreadIDs: Set<String>
    /// Writes the page's draft before a comment is anchored on it, so the
    /// comment's place is a place in the saved text.
    let prepareToComment: () async throws -> Void
    let onClose: () -> Void
    let onError: (String) -> Void

    @State private var filter: PageCommentFilter = .open
    @State private var newCommentDraft = ""
    @State private var replyDrafts: [String: String] = [:]
    @State private var editingCommentID: String?
    @State private var editDraft = ""
    @State private var expandedThreadIDs: Set<String> = []
    @State private var pendingDeletion: PageCommentDeletion?
    @State private var authorRecordName: String?
    @State private var isSending = false
    @FocusState private var focusedField: PageCommentField?

    private var threads: [ArtifactCommentThread] { ArtifactCommentThread.threads(from: comments) }
    private var openThreads: [ArtifactCommentThread] { threads.filter { !$0.isResolved } }
    private var resolvedThreads: [ArtifactCommentThread] { threads.filter(\.isResolved) }
    private var shownThreads: [ArtifactCommentThread] { filter == .open ? openThreads : resolvedThreads }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if let selection = pendingSelection, selection.hasText {
                            newCommentComposer(on: selection)
                        }
                        threadList
                        chatLinksSection
                    }
                    .padding(10)
                }
                .onChange(of: selectedThreadID) { _, id in
                    guard let id else { return }
                    // A thread opened from its words in the page: shown here,
                    // under the filter it belongs to.
                    if let thread = threads.first(where: { $0.id == id }) {
                        filter = thread.isResolved ? .resolved : .open
                    }
                    withAnimation(.easeOut(duration: 0.2)) { scroller.scrollTo(id, anchor: .top) }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .task { authorRecordName = await vm.commentAuthorRecordName() }
        .onChange(of: pendingSelection) { _, selection in
            if selection?.hasText == true { focusedField = .newComment }
        }
        .confirmationDialog(
            pendingDeletion?.title ?? "",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { deletion in
            Button("Delete", role: .destructive) { delete(deletion) }
            Button("Cancel", role: .cancel) {}
        } message: { deletion in
            Text(deletion.message)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Comments")
                .zoomedSystemFont(size: 13, weight: .semibold)
            Spacer()
            Menu {
                Picker("Filter comments", selection: $filter) {
                    ForEach(PageCommentFilter.allCases) { choice in
                        Text(choice == .resolved && !resolvedThreads.isEmpty ? "Resolved · \(resolvedThreads.count)" : choice.title)
                            .tag(choice)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 3) {
                    Text(filter.title)
                    Image(systemName: "chevron.down").imageScale(.small)
                }
                .zoomedSystemFont(size: 11, weight: .medium)
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Filter comments")
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.hoverWash)
            .help("Close comments")
            .accessibilityLabel("Close comments")
        }
        .padding(14)
    }

    // MARK: New comment

    private func newCommentComposer(on selection: ArtifactEditorSelection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            quoteLine(selection.text, detached: false)
            TextField("Add a comment…", text: $newCommentDraft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($focusedField, equals: .newComment)
                .onSubmit { addComment(on: selection) }
                .onKeyPress(.escape) {
                    cancelNewComment()
                    return .handled
                }
            HStack {
                Spacer()
                Button("Cancel") { cancelNewComment() }
                    .buttonStyle(.hoverWash)
                Button("Comment") { addComment(on: selection) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isSending || newCommentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .zoomedSystemFont(size: 11)
        }
        .padding(11)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1))
    }

    // MARK: Threads

    @ViewBuilder
    private var threadList: some View {
        if shownThreads.isEmpty {
            emptyState
        } else {
            ForEach(shownThreads) { thread in
                threadCard(thread)
                    .id(thread.id)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            if filter == .open, !resolvedThreads.isEmpty {
                Text("No open comment threads.")
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.secondary)
                Button("Show resolved threads") { filter = .resolved }
                    .buttonStyle(.hoverWash(tint: Color.accentColor))
                    .zoomedSystemFont(size: 11)
            } else if filter == .resolved {
                Text("No resolved comment threads.")
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.secondary)
            } else if pendingSelection == nil {
                Text("No comments yet")
                    .zoomedSystemFont(size: 12, weight: .medium)
                Text("Select text to add a comment")
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
    }

    private func threadCard(_ thread: ArtifactCommentThread) -> some View {
        let isSelected = selectedThreadID == thread.id
        let showsReplies = isSelected || expandedThreadIDs.contains(thread.id)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 6) {
                quoteLine(thread.root.anchorQuote, detached: detachedThreadIDs.contains(thread.id))
                Spacer(minLength: 4)
                Button {
                    setResolved(thread, !thread.isResolved)
                } label: {
                    Image(systemName: thread.isResolved ? "arrow.uturn.backward.circle" : "checkmark.circle")
                }
                .buttonStyle(.hoverWash)
                .help(thread.isResolved ? "Reopen" : "Resolve comment")
                .accessibilityLabel(thread.isResolved ? "Reopen" : "Resolve comment")
            }
            message(thread.root, in: thread)
            if !thread.replies.isEmpty {
                if showsReplies {
                    ForEach(thread.replies) { reply in
                        message(reply, in: thread)
                            .padding(.leading, 10)
                    }
                } else {
                    Button(thread.replies.count == 1 ? "Show 1 reply" : "Show \(thread.replies.count) replies") {
                        expandedThreadIDs.insert(thread.id)
                    }
                    .buttonStyle(.hoverWash(tint: Color.accentColor))
                    .zoomedSystemFont(size: 10, weight: .medium)
                }
            }
            if thread.isResolved, let resolvedAt = thread.root.resolvedAt {
                Text("Resolved · \(resolvedAt.formatted(.relative(presentation: .named)))")
                    .zoomedSystemFont(size: 9)
                    .foregroundStyle(.tertiary)
            }
            if isSelected, !thread.isResolved {
                replyField(for: thread)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(isSelected ? 0.07 : (thread.isResolved ? 0.02 : 0.04)),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onTapGesture { selectedThreadID = isSelected ? nil : thread.id }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Comment thread")
        .accessibilityHint("Open comment on \(thread.root.anchorQuote)")
    }

    /// The passage a thread is on, or Codex's "Original text unavailable" when
    /// its words are gone from the page.
    @ViewBuilder
    private func quoteLine(_ quote: String, detached: Bool) -> some View {
        let shown = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        Text(detached || shown.isEmpty ? "Original text unavailable" : shown)
            .zoomedSystemFont(size: 10)
            .italic(detached || shown.isEmpty)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .padding(.leading, 8)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(detached ? Color.secondary.opacity(0.18) : Color.yellow.opacity(0.7))
                    .frame(width: 2)
            }
    }

    private func message(_ comment: ArtifactCommentRecord, in thread: ArtifactCommentThread) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(isMine(comment) ? "You" : comment.authorDisplayName)
                    .zoomedSystemFont(size: 10, weight: .semibold)
                Text(comment.createdAt, style: .relative)
                    .zoomedSystemFont(size: 9)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                if isMine(comment) || comment.id == thread.id {
                    messageMenu(comment, in: thread)
                }
            }
            if editingCommentID == comment.id {
                TextField("Comment text", text: $editDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($focusedField, equals: .edit(comment.id))
                    .onSubmit { saveEdit(comment) }
                    .onKeyPress(.escape) {
                        editingCommentID = nil
                        return .handled
                    }
                HStack {
                    Spacer()
                    Button("Cancel") { editingCommentID = nil }
                        .buttonStyle(.hoverWash)
                    Button("Save") { saveEdit(comment) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .zoomedSystemFont(size: 11)
            } else {
                Text(comment.body)
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(thread.isResolved ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func messageMenu(_ comment: ArtifactCommentRecord, in thread: ArtifactCommentThread) -> some View {
        Menu {
            if isMine(comment) {
                Button("Edit comment") {
                    editDraft = comment.body
                    editingCommentID = comment.id
                    focusedField = .edit(comment.id)
                }
                Button("Delete comment") {
                    pendingDeletion = .comment(comment.id, opensThread: comment.id == thread.id && !thread.replies.isEmpty)
                }
            }
            Button("Copy comment") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(comment.body, forType: .string)
            }
            if comment.id == thread.id, thread.root.authorRecordName == authorRecordName || authorRecordName == nil {
                Divider()
                Button("Delete thread", role: .destructive) {
                    pendingDeletion = .thread(thread.id)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .zoomedSystemFont(size: 10)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Comment actions")
        .accessibilityLabel("Comment actions")
    }

    private func replyField(for thread: ArtifactCommentThread) -> some View {
        let draft = Binding(
            get: { replyDrafts[thread.id] ?? "" },
            set: { replyDrafts[thread.id] = $0 }
        )
        return HStack(alignment: .bottom, spacing: 6) {
            TextField("Reply…", text: draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($focusedField, equals: .reply(thread.id))
                .onSubmit { reply(to: thread) }
            Button("Reply") { reply(to: thread) }
                .buttonStyle(.hoverWash(tint: Color.accentColor))
                .disabled(isSending || draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .zoomedSystemFont(size: 11)
        .padding(.top, 2)
    }

    // MARK: Chats

    /// The conversations this page's passages started, ForeverLM's addition
    /// under the comments. One row per passage, newest first, showing the
    /// words that were asked about: the quote tells the writer which of five
    /// conversations about the page is the one they want, and it stays
    /// readable after the paragraph has been rewritten.
    @ViewBuilder
    private var chatLinksSection: some View {
        if !chatLinks.isEmpty {
            Text("CHATS")
                .zoomedSystemFont(size: 9, weight: .semibold)
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
                .padding(.horizontal, 2)
            ForEach(chatLinks) { entry in
                Button {
                    vm.requestResumeReviewSession(entry.session.id)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "bubble.left.and.text.bubble.right")
                                .zoomedSystemFont(size: 9)
                                .foregroundStyle(Color.accentColor)
                            Text(entry.displayTitle)
                                .zoomedSystemFont(size: 11, weight: .medium)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 4)
                            Text(entry.link.createdAt, style: .relative)
                                .zoomedSystemFont(size: 9)
                                .foregroundStyle(.tertiary)
                        }
                        Text(entry.link.anchorQuote)
                            .zoomedSystemFont(size: 10)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .padding(.leading, 8)
                            .overlay(alignment: .leading) {
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.28))
                                    .frame(width: 2)
                            }
                        if !entry.link.sectionTitle.isEmpty {
                            Text(entry.link.sectionTitle)
                                .zoomedSystemFont(size: 9)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(11)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .help("Open the chat that started on this passage")
                .contextMenu {
                    OtherWindowMenuItem(.chat(entry.session.id))
                    Divider()
                    Button("Forget This Link") {
                        Task {
                            await vm.forgetArtifactChatLink(entry.link.id)
                            chatLinks = await vm.artifactChatLinks(artifactID)
                        }
                    }
                }
                .accessibilityLabel("Chat \(entry.displayTitle), about: \(entry.link.anchorQuote)")
            }
        }
    }

    // MARK: Actions

    private func isMine(_ comment: ArtifactCommentRecord) -> Bool {
        guard let authorRecordName else { return false }
        return comment.authorRecordName == authorRecordName
    }

    private func reload() async throws {
        comments = try await vm.artifactComments(artifactID)
    }

    private func cancelNewComment() {
        newCommentDraft = ""
        pendingSelection = nil
    }

    private func addComment(on selection: ArtifactEditorSelection) {
        let body = newCommentDraft
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isSending else { return }
        isSending = true
        Task {
            defer { isSending = false }
            do {
                try await prepareToComment()
                let comment = try await vm.addArtifactComment(artifactID: artifactID, body: body, selection: selection)
                try await reload()
                newCommentDraft = ""
                pendingSelection = nil
                filter = .open
                selectedThreadID = comment.id
            } catch {
                onError(error.localizedDescription)
            }
        }
    }

    private func reply(to thread: ArtifactCommentThread) {
        let body = replyDrafts[thread.id] ?? ""
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isSending else { return }
        isSending = true
        Task {
            defer { isSending = false }
            do {
                _ = try await vm.replyToArtifactComment(thread.id, body: body)
                try await reload()
                replyDrafts[thread.id] = nil
                expandedThreadIDs.insert(thread.id)
            } catch {
                onError(error.localizedDescription)
            }
        }
    }

    private func saveEdit(_ comment: ArtifactCommentRecord) {
        let body = editDraft
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            do {
                try await vm.editArtifactComment(comment.id, body: body)
                try await reload()
                editingCommentID = nil
            } catch {
                onError(error.localizedDescription)
            }
        }
    }

    private func setResolved(_ thread: ArtifactCommentThread, _ resolved: Bool) {
        Task {
            do {
                try await vm.setArtifactCommentResolved(thread.id, resolved: resolved)
                try await reload()
                if resolved, selectedThreadID == thread.id { selectedThreadID = nil }
            } catch {
                onError(error.localizedDescription)
            }
        }
    }

    private func delete(_ deletion: PageCommentDeletion) {
        Task {
            do {
                switch deletion {
                case .comment(let id, _):
                    try await vm.deleteArtifactComment(id)
                case .thread(let id):
                    try await vm.deleteArtifactCommentThread(id)
                    if selectedThreadID == id { selectedThreadID = nil }
                }
                try await reload()
                // A thread handed to its first reply goes on under that id.
                if let selected = selectedThreadID, !comments.contains(where: { $0.id == selected }) {
                    selectedThreadID = nil
                }
            } catch {
                onError(error.localizedDescription)
            }
        }
    }
}

/// What a Delete in the Comments panel takes out, and how its confirmation
/// reads (Codex's `confirmDeleteMessage` / `confirmDeleteThread`).
enum PageCommentDeletion: Equatable {
    case comment(String, opensThread: Bool)
    case thread(String)

    var title: String {
        switch self {
        case .comment: "Delete this comment?"
        case .thread: "Delete this thread?"
        }
    }

    var message: String {
        switch self {
        case .comment(_, let opensThread):
            opensThread ? "The comment text will be removed, but replies will remain." : "The comment will be removed."
        case .thread: "This removes the thread and all its messages."
        }
    }
}

private enum PageCommentField: Hashable {
    case newComment
    case reply(String)
    case edit(String)
}
