import SwiftUI
import Combine
import UniformTypeIdentifiers
import PDFKit
import WebKit
import AppKit

struct ReviewSessionsPanel: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(\.openURL) private var openURL
    let compact: Bool
    /// When set, only sessions for this Notebook are listed.
    let notebookGoal: LearningGoalRecord?
    /// When true, omits the opaque panel background so the view sits flush inside glass overlays.
    let embeddedInGlass: Bool
    let currentSessionID: (@MainActor () -> String?)?
    let resumeSession: (@MainActor (ReviewSessionRecord) -> Void)?
    let hideSidebar: (() -> Void)?
    let hideButtonSystemImage: String
    let hideButtonHelp: String
    let deletedActiveSession: (@MainActor () -> Void)?
    @State private var searchText = ""
    @State private var editingSession: ReviewSessionRecord?
    @State private var viewingSession: ReviewSessionRecord?

    init(
        compact: Bool = false,
        notebookGoal: LearningGoalRecord? = nil,
        embeddedInGlass: Bool = false,
        currentSessionID: (@MainActor () -> String?)? = nil,
        resumeSession: (@MainActor (ReviewSessionRecord) -> Void)? = nil,
        hideSidebar: (() -> Void)? = nil,
        hideButtonSystemImage: String = "sidebar.left",
        hideButtonHelp: String = "Hide previous chats",
        deletedActiveSession: (@MainActor () -> Void)? = nil
    ) {
        self.compact = compact
        self.notebookGoal = notebookGoal
        self.embeddedInGlass = embeddedInGlass
        self.currentSessionID = currentSessionID
        self.resumeSession = resumeSession
        self.hideSidebar = hideSidebar
        self.hideButtonSystemImage = hideButtonSystemImage
        self.hideButtonHelp = hideButtonHelp
        self.deletedActiveSession = deletedActiveSession
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !embeddedInGlass {
                Divider()
            }
            sessionList
        }
        .background(embeddedInGlass ? Color.clear : Color(nsColor: .windowBackgroundColor))
        .task {
            await vm.loadReviewSessionLinks()
        }
        .onChange(of: searchText) { _, newValue in
            Task { await vm.updateReviewTranscriptSearch(newValue) }
        }
        .sheet(item: $editingSession) { session in
            ReviewSessionSourcesEditor(session: session)
                .environment(vm)
        }
        .sheet(item: $viewingSession) { session in
            ReviewSessionTranscriptSheet(session: session)
                .environment(vm)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                sessionSearchField
                Spacer()
                if let hideSidebar {
                    Button(action: hideSidebar) {
                        Image(systemName: hideButtonSystemImage)
                    }
                    .buttonStyle(.hoverWash)
                    .controlSize(.small)
                    .help(hideButtonHelp)
                }
            }

            sessionFilterLabel
        }
        .padding(.horizontal, embeddedInGlass ? 16 : (compact ? 10 : 14))
        // Inside a notebook detail column the column header already provides top
        // spacing; keep the field flush so it lines up with the Sources search.
        .padding(.top, notebookGoal != nil ? 0 : (embeddedInGlass ? 10 : (compact ? 10 : 14)))
        .padding(.bottom, embeddedInGlass ? 10 : (compact ? 10 : 14))
    }

    private var sessionSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search sessions", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.hoverWash)
                .help("Clear search")
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .frame(maxWidth: compact ? .infinity : 260)
    }

    @ViewBuilder
    private var sessionFilterLabel: some View {
        if let filterLabel = reviewFilterLabel {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle.fill")
                    .foregroundStyle(Color.accentColor)
                Text("Filtered to: \(filterLabel)")
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                Button {
                    vm.reviewSessionFilter = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.hoverWash)
                .help("Clear filter")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var reviewFilterLabel: String? {
        switch vm.reviewSessionFilter {
        case .source(let sourceId):
            return vm.articles.first(where: { $0.id == sourceId })?.title
        case .group(let groupName):
            if vm.allCourseGroupNames.contains(groupName) {
                return vm.courseDisplayName(groupName)
            }
            if vm.allMeetingGroupNames.contains(groupName) {
                return vm.meetingDisplayName(groupName)
            }
            return vm.bookDisplayName(groupName)
        case .none:
            return nil
        }
    }

    @ViewBuilder
    private var sessionList: some View {
        let sessions: [ReviewSessionRecord] = {
            if let notebookGoal {
                return vm.reviewSessionsForNotebook(notebookGoal, matching: searchText)
            }
            return vm.filteredReviewSessionLinks(matching: searchText)
        }()
        if sessions.isEmpty, notebookGoal != nil {
            // Inside a notebook column the header already carries "Start review",
            // so this state stays quiet: no competing button, no oversized art.
            VStack(spacing: 6) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .zoomedSystemFont(size: 20)
                    .foregroundStyle(.tertiary)
                Text(searchText.isEmpty ? emptySessionsTitle : "No matching sessions")
                    .zoomedSystemFont(size: 12, weight: .semibold)
                    .foregroundStyle(.secondary)
                Text(emptySessionsMessage)
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 260)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 16)
            .padding(.top, 48)
        } else if sessions.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "brain.head.profile")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text(searchText.isEmpty ? emptySessionsTitle : "No matching sessions")
                    .font(.headline)
                Text(emptySessionsMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            ScrollView {
                LazyVStack(spacing: compact ? 2 : 4) {
                    ForEach(sessions) { session in
                        ReviewSessionRow(
                            session: session,
                            linkedSources: vm.linkedSources(for: session),
                            style: compact ? .compact : .full,
                            openSource: { source in
                                Task { await vm.openSourceInReader(source.id) }
                            },
                            open: {
                                if let urlString = session.url, let url = URL(string: urlString) {
                                    openURL(url)
                                }
                            },
                            resume: {
                                if let resumeSession {
                                    resumeSession(session)
                                } else {
                                    vm.requestResumeReviewSession(session.id)
                                }
                            },
                            editSources: {
                                editingSession = session
                            },
                            viewTranscript: {
                                viewingSession = session
                            },
                            delete: {
                                Task {
                                    let removedOpenSession = await MainActor.run {
                                        guard let currentSessionID else { return false }
                                        return currentSessionID() == session.id
                                    }
                                    if removedOpenSession {
                                        await MainActor.run {
                                            deletedActiveSession?()
                                        }
                                    }
                                    await vm.deleteReviewSessionLink(session.id)
                                }
                            },
                            copyQuizPrompt: {
                                copyToClipboardString(quizPromptText(for: session))
                            }
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, compact ? 6 : 10)
                .padding(.vertical, 6)
            }
        }
    }

    private var emptySessionsTitle: String {
        notebookGoal == nil ? "No saved sessions yet" : "No chats for this notebook yet"
    }

    private var emptySessionsMessage: String {
        if notebookGoal != nil {
            return "Reviews you start here land in this list, along with chats in Claude or ChatGPT whose sources are in this notebook, saved through the MCP server."
        }
        return "In-app reviews appear here, along with chats saved from Claude, ChatGPT, or another assistant through the MCP server. Search covers full transcript text."
    }

    private func quizPromptText(for session: ReviewSessionRecord) -> String {
        let title = session.title
        let summaryLine = (session.summary?.isEmpty == false) ? "\nPrevious summary: \(session.summary!)" : ""
        if session.isLocalMCPSession {
            return """
            We previously had a review session titled "\(title)". Please use ForeverLM to re-quiz me on the ideas we discussed — same Socratic style as before. If I really don't know something I can ask you for the answer, but try to push me first.

            To see what we covered, open the saved transcript in ForeverLM or call the `get_review_sessions` MCP tool with topic "\(title)" and look up past exchanges.\(summaryLine)
            """
        }
        let linkLine = session.url.map { "\nPrevious session: \($0)" } ?? ""
        return """
        We previously had a review session titled "\(title)". Please use ForeverLM to quiz me again on the ideas we discussed — same Socratic style. If I really don't know, I can ask you for the answer, but try to push me first.\(linkLine)
        """
    }

    private func copyToClipboardString(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

enum ReviewSessionRowStyle {
    case full
    case compact
}

struct ReviewSessionRow: View {
    let session: ReviewSessionRecord
    let linkedSources: [StudioArticle]
    let style: ReviewSessionRowStyle
    let openSource: (StudioArticle) -> Void
    let open: () -> Void
    let resume: () -> Void
    let editSources: () -> Void
    let viewTranscript: () -> Void
    let delete: () -> Void
    let copyQuizPrompt: () -> Void

    @State private var copied = false
    @State private var isHovered = false

    var body: some View {
        Group {
            switch style {
            case .compact:
                compactBody
            case .full:
                fullBody
            }
        }
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.secondary.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { inside in
            isHovered = inside
        }
        .contextMenu {
            sessionMenuItems
        }
        .onDrag {
            StudioDragVisibility.shared.begin()
            return reviewSessionDragProvider(for: ReviewSessionTransfer(from: session))
        }
        // The help goes on a group of its own: on a plain container it
        // replaced the open button's hint and the menu's "More actions".
        .accessibilityElement(children: .contain)
        .help(session.url ?? session.summary ?? session.title)
    }

    private var compactBody: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Button(action: primaryAction) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(session.title)
                                .font(.caption.weight(.medium))
                                .lineLimit(2)
                            if session.isExternalLink {
                                Image(systemName: "arrow.up.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        Text(compactSubtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint(primaryActionAccessibilityHint)

                ReviewSessionLinkedSourcesControl(
                    linkedSources: linkedSources,
                    onOpenSource: openSource
                )
            }

            sessionActionsMenu
        }
        .padding(.vertical, 5)
    }

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Button(action: primaryAction) {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(session.title)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(2)
                                if session.isExternalLink {
                                    Image(systemName: "arrow.up.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 4)
                            }
                            HStack(spacing: 6) {
                                Text(subtitleLabel)
                                if let modelName = session.modelDisplayName {
                                    Text(modelName)
                                }
                                Text(session.createdAt.formatted(date: .abbreviated, time: .omitted))
                                if session.isLocalMCPSession {
                                    if session.exchangeCount > 0 {
                                        Text("\(session.exchangeCount) Q/A")
                                    }
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)

                            if let url = session.url {
                                Text(url)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            } else if let summary = session.summary, !summary.isEmpty {
                                Text(summary)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }

                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint(primaryActionAccessibilityHint)

                sessionActionsMenu
            }

            ReviewSessionLinkedSourcesControl(
                linkedSources: linkedSources,
                onOpenSource: openSource
            )
        }
        .padding(.vertical, 6)
    }

    /// Built only under the pointer (or while it shows Copied), a clear box
    /// holding its place: a menu at opacity 0 is still a live control, and
    /// while an assistive app reads the screen SwiftUI walks every control in
    /// the window for each one an update builds (2026-10-03). The box is the
    /// size the borderless popup button draws at whatever its label's frame,
    /// 20×14 (measured 2026-10-03). The right-click has the same items.
    @ViewBuilder
    private var sessionActionsMenu: some View {
        if isHovered || copied {
            Menu {
                sessionMenuItems
            } label: {
                Image(systemName: copied ? "checkmark" : "ellipsis")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(copied ? .green : .secondary)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(isHovered || copied ? Color.secondary.opacity(0.14) : Color.clear)
                    )
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
        } else {
            Color.clear
                .frame(width: 20, height: 14)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var sessionMenuItems: some View {
        if session.isExternalLink {
            Button(action: open) {
                Label("Open Session", systemImage: "arrow.up.right")
            }
        }
        if session.isLocalMCPSession {
            Button(action: resume) {
                Label("Resume Chat", systemImage: "arrow.clockwise")
            }
            OtherWindowMenuItem(.chat(session.id))
            KnowledgeMapAddToCanvasMenu(refs: [KnowledgeMapOutside.chatRef(session.id)])
        }
        Button(action: copyPromptAction) {
            Label("Copy Quiz Prompt", systemImage: "quote.bubble")
        }
        Button(action: editSources) {
            Label("Edit Linked Sources...", systemImage: "link")
        }
        if session.exchangeCount > 0 {
            Button(action: viewTranscript) {
                Label("View Transcript", systemImage: "text.bubble")
            }
        }
        Button(role: .destructive, action: delete) {
            Label("Remove", systemImage: "trash")
        }
    }

    private var compactSubtitle: String {
        var parts = [
            session.isLocalMCPSession ? "In-App" : session.provider.rawValue,
            session.createdAt.formatted(date: .abbreviated, time: .omitted)
        ]
        if let modelName = session.modelDisplayName {
            parts.insert(modelName, at: 1)
        }
        if session.exchangeCount > 0 {
            parts.append("\(session.exchangeCount) Q/A")
        }
        return parts.joined(separator: " · ")
    }

    private func copyPromptAction() {
        copyQuizPrompt()
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private func primaryAction() {
        if session.isExternalLink {
            open()
        } else if session.isLocalMCPSession {
            resume()
        }
    }

    private var subtitleLabel: String {
        session.isLocalMCPSession ? "In-App Review" : session.provider.rawValue
    }

    private var accessibilityLabel: String {
        if let modelName = session.modelDisplayName {
            return "\(subtitleLabel), \(modelName), \(session.title)"
        }
        return "\(subtitleLabel), \(session.title)"
    }

    private var primaryActionAccessibilityHint: String {
        session.isExternalLink ? "Opens the saved external chat." : "Opens this in-app review chat."
    }
}

struct ReviewSessionLinkedSourcesControl: View {
    let linkedSources: [StudioArticle]
    let onOpenSource: (StudioArticle) -> Void

    @SyncedStorage("metadataVisibility") private var metadataVisibility = MetadataVisibilitySettings()
    @State private var isPopoverPresented = false

    var body: some View {
        if linkedSources.isEmpty {
            Text("No linked sources")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else {
            Button {
                isPopoverPresented = true
            } label: {
                Label(linkedSourcesLabel, systemImage: "link")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0))
            .help("Show linked sources")
            .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
                linkedSourcesPopover
            }
        }
    }

    private var linkedSourcesLabel: String {
        if linkedSources.count == 1 {
            return linkedSources[0].title
        }
        return "\(linkedSources.count) linked sources"
    }

    private var linkedSourcesPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Linked sources")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(linkedSources) { source in
                        Button {
                            isPopoverPresented = false
                            onOpenSource(source)
                        } label: {
                            ArticleRow(
                                article: source,
                                metadataVisibility: metadataVisibility
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.hoverWash)
                        .opensInOtherWindow(source)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .frame(width: 400)
        .frame(maxHeight: 440)
    }
}

private struct ReviewTranscriptExchangeSnapshot: Sendable {
    let id: String
    let sequenceNumber: Int
    let question: String
    let learnerAnswer: String?
    let evaluation: String?
    let score: Double?
}

private struct ReviewTranscriptPresentationMessage: Identifiable, Sendable {
    enum Role: Equatable, Sendable {
        case assistant
        case learner
        case transcript

        var label: String {
            switch self {
            case .assistant: "Assistant"
            case .learner: "Learner"
            case .transcript: "Transcript"
            }
        }
    }

    let id: String
    let role: Role
    let text: String
    let score: Double?
}

private enum ReviewTranscriptPresentation {
    static func messages(
        from snapshots: [ReviewTranscriptExchangeSnapshot]
    ) -> [ReviewTranscriptPresentationMessage] {
        var result: [ReviewTranscriptPresentationMessage] = []
        for exchange in snapshots.sorted(by: { $0.sequenceNumber < $1.sequenceNumber }) {
            let question = exchange.question.trimmingCharacters(in: .whitespacesAndNewlines)
            let answer = exchange.learnerAnswer?.trimmingCharacters(in: .whitespacesAndNewlines)
            let evaluation = exchange.evaluation?.trimmingCharacters(in: .whitespacesAndNewlines)

            // Before per-turn persistence, MCP exports were saved as one learner
            // answer under a synthetic heading. Expand those immutable rows only
            // for presentation so existing reviews immediately become readable.
            if question == "Review transcript", let answer, !answer.isEmpty {
                let legacyMessages = ReviewTranscriptParser.messages(from: answer)
                if !legacyMessages.isEmpty {
                    result.append(contentsOf: legacyMessages.enumerated().map { index, message in
                        ReviewTranscriptPresentationMessage(
                            id: "\(exchange.id)-legacy-\(index)",
                            role: message.role == .assistant ? .assistant : .learner,
                            text: message.text,
                            score: nil
                        )
                    })
                    continue
                }
            }

            if question == "Exported chat transcript", let answer, !answer.isEmpty {
                result.append(
                    ReviewTranscriptPresentationMessage(
                        id: "\(exchange.id)-transcript",
                        role: .transcript,
                        text: answer,
                        score: exchange.score
                    )
                )
                continue
            }
            // The placeholder a voice recorder writes when the learner spoke
            // first names the absence of a question; it is not a tutor line.
            if !question.isEmpty, question != RealtimeExchangeLedger.openConversationQuestion {
                result.append(
                    ReviewTranscriptPresentationMessage(
                        id: "\(exchange.id)-assistant-question",
                        role: .assistant,
                        text: question,
                        score: answer?.isEmpty == false ? nil : exchange.score
                    )
                )
            }
            if let answer, !answer.isEmpty {
                result.append(
                    ReviewTranscriptPresentationMessage(
                        id: "\(exchange.id)-learner",
                        role: .learner,
                        text: answer,
                        score: exchange.score
                    )
                )
            }
            if let evaluation, !evaluation.isEmpty {
                result.append(
                    ReviewTranscriptPresentationMessage(
                        id: "\(exchange.id)-assistant-evaluation",
                        role: .assistant,
                        text: evaluation,
                        score: nil
                    )
                )
            }
        }
        return result
    }
}

struct ReviewSessionTranscriptSheet: View {
    let session: ReviewSessionRecord
    @Environment(StudioViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var transcriptMessages: [ReviewTranscriptPresentationMessage] = []
    @State private var isPreparingTranscript = true

    private var exchanges: [ReviewExchangeRecord] {
        vm.reviewSessionExchanges[session.id] ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text("Exported chat transcript")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    copyToClipboard(transcriptText)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .disabled(transcriptText.isEmpty)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)

            Divider()

            if isPreparingTranscript {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if exchanges.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.bubble")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("No transcript saved")
                        .font(.headline)
                    Text("Complete the review after answering at least one question to store the chat here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(transcriptMessages) { message in
                            transcriptBubble(message)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 520)
        .task {
            await vm.loadReviewSessionExchanges(session.id)
            await prepareTranscriptMessages()
        }
    }

    private func transcriptBubble(
        _ message: ReviewTranscriptPresentationMessage
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .learner {
                Spacer(minLength: 72)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(message.role.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let score = message.score {
                        Text(String(format: "%.0f%%", score * 100))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(score >= 0.7 ? .green : (score >= 0.4 ? .orange : .red))
                    }
                }
                Text(message.text)
                    .font(.body)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                message.role == .learner
                    ? Color.accentColor.opacity(0.12)
                    : Color.secondary.opacity(0.09),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .frame(maxWidth: 680, alignment: .leading)
            if message.role != .learner {
                Spacer(minLength: 72)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @MainActor
    private func prepareTranscriptMessages() async {
        let snapshots = exchanges.map { exchange in
            ReviewTranscriptExchangeSnapshot(
                id: exchange.id,
                sequenceNumber: exchange.sequenceNumber,
                question: exchange.question,
                learnerAnswer: exchange.userAnswer,
                evaluation: exchange.evaluation,
                score: exchange.score
            )
        }
        transcriptMessages = await Task.detached(priority: .userInitiated) {
            ReviewTranscriptPresentation.messages(from: snapshots)
        }.value
        isPreparingTranscript = false
    }

    private var transcriptText: String {
        transcriptMessages
            .map { "\($0.role.label): \($0.text)" }
            .joined(separator: "\n\n")
    }

    private func copyToClipboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

struct ReviewSessionSourcesEditor: View {
    let session: ReviewSessionRecord
    @Environment(StudioViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: Set<String> = []
    @State private var search: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Edit Linked Sources")
                        .font(.headline)
                    Text(session.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text("\(selectedIDs.count) linked")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search sources", text: $search)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            List {
                ForEach(filteredArticles) { article in
                    Button {
                        if selectedIDs.contains(article.id) {
                            selectedIDs.remove(article.id)
                        } else {
                            selectedIDs.insert(article.id)
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selectedIDs.contains(article.id) ? "checkmark.square.fill" : "square")
                                .foregroundStyle(selectedIDs.contains(article.id) ? Color.accentColor : .secondary)
                            sourceTypeIconView(for: article.sourceType)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(article.title)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                if let detail = (article.sourceType == .book || article.sourceType == .course
                                    ? vm.sourceGroupTitle(for: article) : nil) ?? article.displayDomain {
                                    Text(detail)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.hoverWash)
                }
            }
            .listStyle(.inset)

            Divider()

            HStack {
                Button("Clear All") {
                    selectedIDs.removeAll()
                }
                .disabled(selectedIDs.isEmpty)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let ids = Array(selectedIDs)
                    Task {
                        await vm.updateReviewSessionSources(session.id, sourceIDs: ids)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(14)
        }
        .frame(minWidth: 460, minHeight: 500)
        .onAppear {
            selectedIDs = Set(session.sourceIDs)
        }
    }

    private var filteredArticles: [StudioArticle] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = vm.articles.sorted { a, b in
            let aSel = selectedIDs.contains(a.id)
            let bSel = selectedIDs.contains(b.id)
            if aSel != bSel { return aSel && !bSel }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        guard !query.isEmpty else { return base }
        return base.filter {
            $0.title.lowercased().contains(query) || $0.domain.lowercased().contains(query)
        }
    }

    @ViewBuilder
    private func sourceTypeIconView(for type: StudioSourceType) -> some View {
        if type == .xPost {
            XLogoShape()
                .fill(sourceTypeColor(type), style: FillStyle(eoFill: true))
                .frame(width: 12, height: 12)
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: sourceTypeIcon(type))
                .font(.subheadline)
                .foregroundStyle(sourceTypeColor(type))
                .frame(width: 18, height: 18)
        }
    }

    private func sourceTypeIcon(_ type: StudioSourceType) -> String {
        switch type {
        case .article, .unclassified: return "doc.richtext"
        case .paper: return "doc.text.magnifyingglass"
        case .podcast: return "headphones"
        case .book: return "book.closed"
        case .course: return "graduationcap"
        case .meeting: return "person.2.wave.2"
        case .video: return "play.rectangle"
        case .xPost: return "bubble.left"
        case .manual: return "link"
        }
    }

    private func sourceTypeColor(_ type: StudioSourceType) -> Color {
        switch type {
        case .article, .unclassified: return .blue
        case .paper: return .purple
        case .podcast: return .orange
        case .book: return .green
        case .course: return .indigo
        case .meeting: return .teal
        case .video: return .red
        case .xPost: return .primary
        case .manual: return .secondary
        }
    }
}
