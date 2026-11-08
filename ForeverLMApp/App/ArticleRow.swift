import SwiftUI
import Combine
import UniformTypeIdentifiers
import PDFKit
import WebKit
import AppKit

struct ArticleRow: View {
    @Environment(StudioViewModel.self) private var vm
    /// The Sources panel this row is listed in. Optional because a row can be
    /// drawn outside a Studio window's sidebar, where no panel state is
    /// injected; `vm.sidebarTab` (the key window's) is the fallback there.
    @Environment(StudioSidebarStore.self) private var sidebar: StudioSidebarStore?
    /// The window the row is drawn in, which hosts its Edit Details sheet.
    /// Optional for the same reason as `sidebar`.
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?
    private static let thumbnailSize = CGSize(width: 36, height: 48)
    let article: StudioArticle
    let metadataVisibility: MetadataVisibilitySettings
    var hidesBookContext: Bool = false
    /// Grouped rows can let their collection header carry the shared artwork.
    /// Keeping this opt-in at the call site preserves thumbnails everywhere else.
    var showsThumbnail: Bool = true
    /// Book chapters carry their number inside the title ("7) Why Bacteria are Simple").
    /// Lifting it into a fixed-width gutter aligns the chapter titles into one column.
    var showsChapterNumber: Bool = false
    var onShowDrafts: (() -> Void)? = nil
    var dragProvider: (() -> NSItemProvider)? = nil
    /// A meeting session listed among other series' sessions (the Meetings tab
    /// by date), where no series header says whose it is: the row names its
    /// series and leads its metadata with the day.
    var showsMeetingSeries: Bool = false
    /// The notebook the Sources list is marking (`sidebarNotebook(in:)`); nil
    /// everywhere else. The row only hosts the mark: `NotebookMembershipMark`
    /// reads the membership itself, so adding a row never re-runs this one.
    var notebook: SidebarNotebook? = nil
    /// A host that wraps this row in its own full-row wash paints the highlight for
    /// us; painting a second one inside it shows as a double grey edge.
    @Environment(\.containerOwnsRowHoverWash) private var containerOwnsRowHoverWash
    /// The full-window Library's rows say more: when the source was added
    /// (`LibraryRowDetails`).
    @Environment(\.sourcesListLayout) private var sourcesListLayout
    /// `.increased` while the list draws this row selected in the accent colour.
    @Environment(\.backgroundProminence) private var backgroundProminence
    private let dragVisibility = StudioDragVisibility.shared
    @State private var isHovering = false

    /// For books/courses/videos inside a group, strip the group name prefix from the title
    /// since it's already shown in the DisclosureGroup header.
    private var displayTitle: String {
        if showsMeetingSeries, article.sourceType == .meeting {
            return vm.meetingSeriesRowTitle(for: article)
        }
        return vm.sourceRowTitle(for: article)
    }

    /// A meeting session's row title, and the day it stands for when the title
    /// is nothing but a date. The metadata line reads `day` to keep from
    /// printing that day a second time.
    private var meetingRowTitle: StudioViewModel.MeetingSessionRowTitle {
        vm.meetingRowTitle(for: article)
    }

    /// Paper metadata filtered by visibility settings, joined with " · ".
    private var filteredPaperParts: String {
        let parts = article.paperMetadataDisplayParts
        guard parts.count == 3 else { return parts.joined(separator: " · ") }
        var result: [String] = []
        if metadataVisibility.isVisible(.author, for: .paper) { result.append(parts[0]) }
        if metadataVisibility.isVisible(.journal, for: .paper) { result.append(parts[1]) }
        if metadataVisibility.isVisible(.year, for: .paper) { result.append(parts[2]) }
        return result.joined(separator: " · ")
    }

    /// Non-paper metadata parts filtered by visibility, ready for display with separators.
    private var nonPaperMetadataParts: [String] {
        let type = article.sourceType
        guard type != .paper else { return [] }
        var parts: [String] = []

        if type == .book,
           let group = article.parentGroup,
           !hidesBookContext,
           (sidebar?.sidebarTab ?? vm.sidebarTab) != .books {
            parts.append("Book: \(vm.bookDisplayName(group))")
        }

        if let author = article.author, !author.isEmpty, type != .book,
           metadataVisibility.isVisible(.author, for: type) {
            parts.append(author)
        }

        if metadataVisibility.isVisible(.domain, for: type),
           article.parentGroup == nil || (type != .book && type != .course) {
            if type == .video {
                // Videos show the uploader channel, mirroring how podcast
                // episodes show their show name. Legacy rows may still hold
                // playlist-title noise in `domain`; the helper filters it out.
                if let channel = vm.videoChannelName(for: article) {
                    parts.append(channel)
                }
            } else if type == .meeting {
                // Which provider this session came from, in place of the raw
                // host. One Meetings tab spans Google Drive, Read AI and folder
                // imports, so the row itself has to say which one it is:
                // "Google Drive" beats "drive.google.com", and a session pushed
                // in over MCP has no meaningful host to show at all.
                parts.append(MeetingProvider.forOrigin(article.discoveryOrigin).displayName)
            } else if let domain = article.displayDomain {
                parts.append(domain)
            }
        }

        if type == .video, let watchLabel = videoWatchProgress?.displayLabel {
            parts.append(watchLabel)
        }

        if type == .podcast, metadataVisibility.isVisible(.date, for: type) {
            parts.append(article.dateAdded.formatted(date: .abbreviated, time: .omitted))
        }

        if type == .meeting, showsMeetingSeries {
            // Where the day is what the list is ordered by, it leads the line
            // and is printed whatever the date setting says.
            parts.insert(vm.meetingSessionWhen(for: article), at: 0)
        } else if type == .meeting, metadataVisibility.isVisible(.date, for: type) {
            // A row already titled with its day says only the time here, and
            // nothing when no time is known rather than a midnight it made up.
            let rowTitle = meetingRowTitle
            if rowTitle.day != nil {
                if let time = rowTitle.time {
                    parts.append(time.formatted(date: .omitted, time: .shortened))
                }
            } else {
                parts.append(article.dateAdded.formatted(date: .abbreviated, time: .shortened))
            }
        }

        if type != .video, let wc = article.wordCount,
           metadataVisibility.isVisible(.readTime, for: type) {
            parts.append("\(max(1, wc / 200)) min")
        }

        if article.parentGroup == nil, (article.isPDF || article.cachedIsEPUBChapter),
           metadataVisibility.isVisible(.format, for: type) {
            parts.append(article.isPDF ? "PDF" : "EPUB")
        }

        return parts
    }

    private var trackingStatus: SourceConsumptionStatus {
        // Screen record mode: every row reads as new, so a take's titles are
        // not greyed by the learner's own reading history.
        if vm.isScreenRecordModeActive { return .unread }
        return vm.sourceConsumptionStatus(for: article)
    }

    private var dragPreviewSubtitle: String? {
        if article.sourceType == .paper, !filteredPaperParts.isEmpty {
            return filteredPaperParts
        }
        let parts = nonPaperMetadataParts
        if !parts.isEmpty {
            return parts.joined(separator: " · ")
        }
        if article.sourceType == .video {
            return vm.videoChannelName(for: article)
        }
        return article.displayDomain
    }

    /// Read from `sourceThumbnailView` during render, so every lookup here is
    /// cached-only — a cold stat against an evicted iCloud file blocks for seconds.
    private var localDocumentThumbnailPath: String? {
        // A book chapter's thumbnail is its first page of the book's file.
        if let pdfPath = article.cachedResolvedPDFPath { return SourcePDFPages.stored(path: pdfPath, pages: article.bookPages) }
        if article.cachedIsEPUBChapter, let path = article.cachedResolvedLocalPath { return path }
        // A captured or drawn meeting icon is a file this app wrote. Building
        // its path is string work against the content root, with no stat, so it
        // is safe in the cached-only budget this property keeps.
        return MeetingIconService.localArtworkPath(for: article.artworkURL)
    }

    private var paperProcessingStepLabel: String? {
        vm.paperProcessingStepLabel(for: article)
    }

    /// Watch progress for video rows, decoded through the progress store's memo
    /// so render passes never re-run the JSON decode.
    private var videoWatchProgress: VideoWatchProgress? {
        guard article.sourceType == .video else { return nil }
        return vm.readingProgressStore.videoWatchProgress(
            for: article.id,
            fallbackLocator: article.readingPositionLocator
        )
    }

    private var stateBadgeLabel: String? {
        if articleCreditsMessage != nil {
            return "Add your OpenRouter key"
        }
        return nil
    }

    private var articleCreditsMessage: String? {
        guard article.sourceType == .article || article.sourceType == .manual
                || article.sourceType == .unclassified else { return nil }
        return PaperContentPreparationService.articleCreditsMessage(for: article.errorMessage)
    }

    private var paperAttentionReason: PaperAttentionReason? {
        guard paperProcessingStepLabel == nil else { return nil }
        return article.paperAttentionReason(hasUsablePDF: vm.displayHasUsablePDF(article))
    }

    /// The AI browser's reason for thinking this paper is paywalled, when the
    /// row should offer to mark it so. Cached PDF availability only, like the
    /// attention reason it hangs off.
    private var suggestedPaywallReason: String? {
        guard paperProcessingStepLabel == nil else { return nil }
        return article.suggestedPaywallReason(hasUsablePDF: vm.displayHasUsablePDF(article))
    }

    private var paperIngestionFailureDetail: String? {
        guard paperProcessingStepLabel == nil else { return nil }
        return article.paperIngestionFailureDetail
    }

    /// A paper's "PDF needed" or "Metadata incomplete" sits at the end of its
    /// byline rather than alone on a line of its own, unless a status line is
    /// drawn anyway.
    private var paperAttentionRidesByline: Bool {
        article.sourceType == .paper && !filteredPaperParts.isEmpty && visibleStatusLabel == nil
    }

    /// `color`, or the row's own foreground while the list draws the row
    /// selected: the byline's link blue and an orange badge vanish into the
    /// accent-coloured selection.
    private func rowTint(_ color: Color) -> AnyShapeStyle {
        backgroundProminence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(color)
    }

    private var paperIngestionRecoveryAction: PaperIngestionRecoveryAction? {
        article.paperIngestionRecoveryAction(hasUsablePDF: vm.displayHasUsablePDF(article))
    }

    /// The spinner's status text while the source's content is on its way
    /// (`sourceRowActivityLabel`); nil while nothing is.
    private var visibleStatusLabel: String? {
        vm.sourceRowActivityLabel(for: article)
    }

    /// Where the source stands on cards, from the Library's one coverage
    /// read; nil for a source that cannot have cards (a team's copy, hidden,
    /// paywalled, without text), which gets no count and no verdict.
    private var cardState: SourceCardState? {
        vm.sourceCardCoverage.statesByID[article.id]
    }

    /// The row's card count, a muted trailer ("3 cards", "To check",
    /// "Retired"); nothing with no card, where the No Cards pill and the
    /// verdicts say so.
    @ViewBuilder
    private var cardCountTrailer: some View {
        if let label = cardState?.label {
            Text(label)
                .zoomedSystemFont(size: 11)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .textSelection(.disabled)
                .accessibilityLabel(label)
        }
    }

    /// Write Card (Write Another Card once it has some): the source in the
    /// Reader with a blank card beside it, in the notebook the list marks
    /// (`requestWriteCards`).
    private func makeCards() {
        let notebookID = notebook?.notebookID
        if let windowState {
            vm.inWindow(windowState) { vm.requestWriteCards(notebookID: notebookID, sourceIDs: [article.id]) }
        } else {
            vm.requestWriteCards(notebookID: notebookID, sourceIDs: [article.id])
        }
    }

    /// Not Worth Keeping: the source leaves the library as the Sources
    /// list's Remove takes it, with the same Undo banner (`removeArticle`).
    private func notWorthKeeping() {
        let id = article.id
        Task { await vm.removeArticle(id: id) }
    }

    @ViewBuilder
    private var trackingStatusView: some View {
        if article.cachedSupportsReadTracking {
            Button {
                Task { await vm.setArticleRead(article.id, read: !article.isRead) }
            } label: {
                trackingStatusIcon
            }
            // Marks the press as the button's, so a Sources row does not also
            // open its source under it (`SidebarRowControlPress`).
            .buttonStyle(RowControlButtonStyle(sourceIDs: [article.id]))
            .help("\(trackingStatus.title) — mark as \(article.isRead ? "unread" : "read")")
            .accessibilityLabel("\(trackingStatus.title) — mark as \(article.isRead ? "unread" : "read")")
        } else {
            trackingStatusIcon
                .help(trackingStatus.title)
                .accessibilityLabel(trackingStatus.title)
        }
    }

    private var trackingStatusIcon: some View {
        SourceReadStateMark(sourceID: article.id, status: trackingStatus, isRowHovered: isHovering)
    }

    var body: some View {
        rowContent
        // Same neutral wash the app's buttons use, so a source reads as something
        // you can act on. The wash reaches into the list's row insets and the whole
        // of it is hit-testable, matching the button treatment: what lights up is
        // what you can click.
        .padding(.horizontal, 6)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(isHovering && !containerOwnsRowHoverWash ? 0.06 : 0))
        }
        .padding(.horizontal, -6)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // SwiftUI can omit the hover-exit callback while AppKit owns a drag
        // session. Clear both edges of the session so its wash cannot stick.
        .onChange(of: dragVisibility.isDragging) { _, _ in isHovering = false }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .modifier(SourceRowDragModifier(
            itemProvider: dragProvider,
            preview: {
                SourceDragPreview(
                    title: displayTitle,
                    subtitle: dragPreviewSubtitle,
                    sourceType: article.sourceType,
                    isMissing: article.state == .error
                )
            }
        ))
        .task(id: article.artworkURL) {
            await vm.backfillArtworkIfNeeded(article.id)
        }
        .siriSourceAnnotation(article.id)
    }

    @ViewBuilder
    private var rowContent: some View {
        if sourcesListLayout == .compact {
            compactContent
        } else {
            fullContent
        }
    }

    /// One line, as NotebookLM's Sources column draws a source (product
    /// owner, 2026-10-12, of a notebook's column showing the Library's
    /// full rows: "how can this look better. how does gemini notebook do
    /// this?"): a small cover or the kind's glyph, the title, the show,
    /// author or channel faint after it, then the notebook's mark. No line
    /// between rows; what needs the learner (a paper's attention, an error)
    /// is a glyph whose help says it.
    private var compactContent: some View {
        HStack(alignment: .center, spacing: 9) {
            if showsThumbnail {
                compactThumbnail
            }
            // A row whose source changes under it (a new session lands above
            // it in the Meetings list and the rows shift down) must swap its
            // words, not fade one title over the other: the default text
            // transition drew "October 25" and "October 18" on top of each other.
            Text(displayTitle)
                .zoomedSystemFont(size: 13)
                .foregroundStyle(trackingStatus == .unread ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
                .contentTransition(.identity)
            if let byline = compactByline {
                Text(byline)
                    .zoomedSystemFont(size: 12)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.identity)
            }
            Spacer(minLength: 4)
            if let paperProcessingStepLabel {
                ProgressView()
                    .controlSize(.mini)
                    .help(paperProcessingStepLabel)
            } else if let visibleStatusLabel {
                ProgressView()
                    .controlSize(.mini)
                    .help(visibleStatusLabel)
            }
            if let attention = compactAttention {
                Image(systemName: "exclamationmark.circle")
                    .zoomedSystemFont(size: 12)
                    .foregroundStyle(.orange)
                    .help(attention)
                    .accessibilityLabel(attention)
            }
            SourceFollowUpFlag(sourceID: article.id)
            cardCountTrailer
            if let notebook {
                NotebookMembershipMark(
                    sourceIDs: [article.id],
                    notebook: notebook,
                    isRowHovered: isHovering
                )
                .fixedSize()
            }
        }
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .listRowSeparator(.hidden)
    }

    /// The faint words after a compact row's title: a paper's authors, an
    /// episode's show, a video's channel, an article's site.
    private var compactByline: String? {
        let first = article.sourceType == .paper
            ? article.paperMetadataDisplayParts.first
            : nonPaperMetadataParts.first
        guard let first, !first.isEmpty else { return nil }
        return first
    }

    /// What a compact row's orange glyph says, when the source needs the
    /// learner.
    private var compactAttention: String? {
        if paperAttentionReason != nil || paperIngestionFailureDetail != nil || article.isPaperContentCleanupFailure {
            return paperIngestionFailureDetail ?? "This paper needs attention: open it in the Library"
        }
        if article.state == .error { return articleCreditsMessage ?? article.errorMessage ?? "Couldn\u{2019}t load" }
        if article.hasPaywallMarker { return "Paywalled" }
        return nil
    }

    /// The cover or the kind's glyph, 22 pt.
    @ViewBuilder
    private var compactThumbnail: some View {
        if let artworkURLString = article.artworkURL,
           MeetingIconService.localArtworkPath(for: artworkURLString) == nil,
           let artworkURL = URL(string: artworkURLString) {
            CachedAsyncImage(url: artworkURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                default:
                    compactGlyph
                }
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            compactGlyph
        }
    }

    private var compactGlyph: some View {
        Image(systemName: sourceTypeIcon(article.sourceType))
            .zoomedSystemFont(size: 13)
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
    }

    private var fullContent: some View {
        HStack(alignment: .top, spacing: 10) {
            if showsThumbnail {
                sourceThumbnailView
                    .overlay(alignment: .bottom) {
                        if let fraction = videoWatchProgress?.fractionWatched, fraction >= 0.01 {
                            VideoWatchProgressBar(fraction: fraction)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if let visibleStatusLabel, paperProcessingStepLabel == nil {
                            ProgressView()
                                .controlSize(.mini)
                                .padding(3)
                                .background(.regularMaterial, in: Circle())
                                .offset(x: 4, y: 4)
                                .help(visibleStatusLabel)
                        }
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    let chapter: (number: String?, text: String) = showsChapterNumber
                        ? BookChapterTitle.split(displayTitle)
                        : (nil, displayTitle)
                    if showsChapterNumber {
                        // Reserved even when a chapter has no number, so unnumbered
                        // front matter still lines up with the numbered chapters.
                        Text(chapter.number ?? "")
                            .zoomedSystemFont(size: 11, weight: .semibold)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize()
                            .frame(minWidth: 16, alignment: .trailing)
                    }
                    Text(chapter.text)
                        // Chapters read as items *under* their book, so inside a book
                        // group they sit a step below the group header's 13pt medium;
                        // elsewhere the title stays at its normal source-row size.
                        .zoomedSystemFont(size: showsChapterNumber ? 12 : 13,
                                          weight: showsChapterNumber ? .regular : .medium)
                        .foregroundStyle(trackingStatus == .unread ? .primary : .secondary)
                        .lineLimit(2)

                    // Row controls live at the trailing edge, not inline after the
                    // title, so the learning-stage icons line up in one column.
                    Spacer(minLength: 0)

                    // Audio availability is independent of consumption. A source can
                    // have fully generated audio while it is still unread, so never
                    // hide this badge behind the learning-stage status.
                    if ArticleSpeechContent.canAttemptRead(article) {
                        ArticleSpeechCacheDeleteButton(
                            sourceID: article.id,
                            showsSpeakerIcon: true,
                            isRowHovered: isHovering
                        )
                    }

                    if let paperProcessingStepLabel {
                        ProgressView()
                            .controlSize(.mini)
                            .help(paperProcessingStepLabel)
                    }

                    // Screen record mode draws no read badge: it is the
                    // learner's own history.
                    if !vm.isScreenRecordModeActive,
                       article.cachedSupportsReadTracking || trackingStatus != .unread {
                        trackingStatusView
                            .fixedSize()
                    }

                    // The rightmost slot, held on every row while the list
                    // marks a notebook, so the read-state column stays aligned.
                    if let notebook {
                        NotebookMembershipMark(
                            sourceIDs: [article.id],
                            notebook: notebook,
                            isRowHovered: isHovering
                        )
                        .fixedSize()
                    }
                }

                if article.sourceType == .paper, !filteredPaperParts.isEmpty {
                    HStack(spacing: 4) {
                        if article.cachedResolvedPDFPath != nil {
                            Text(filteredPaperParts)
                                .zoomedSystemFont(size: 11)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else if let url = URL(string: article.url), article.url.hasPrefix("http") {
                            Link(destination: url) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.up.right.square")
                                        .zoomedSystemFont(size: 10)
                                    Text(filteredPaperParts)
                                        .zoomedSystemFont(size: 11)
                                        .lineLimit(1)
                                }
                                .foregroundStyle(rowTint(.blue))
                            }
                        } else {
                            Image(systemName: "globe")
                                .zoomedSystemFont(size: 10)
                                .foregroundStyle(.secondary)
                            Text(filteredPaperParts)
                                .zoomedSystemFont(size: 11)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if paperAttentionRidesByline, let paperAttentionReason {
                            Spacer(minLength: 8)
                            paperAttentionBadge(paperAttentionReason)
                        }
                    }
                }

                if !(paperAttentionRidesByline && paperAttentionReason != nil) {
                    HStack(spacing: 6) {
                        let parts = nonPaperMetadataParts
                        if let visibleStatusLabel {
                            Text(visibleStatusLabel)
                                .zoomedSystemFont(size: 11)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                            if index > 0 || visibleStatusLabel != nil {
                                Text("·")
                                    .foregroundStyle(.tertiary)
                            }
                            Text(part)
                                .zoomedSystemFont(size: 11)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }

                        Spacer()

                        // Passages waiting to be followed up, then the card
                        // count: a quiet right column down the list.
                        SourceFollowUpFlag(sourceID: article.id)
                        cardCountTrailer

                        if let paperAttentionReason {
                            paperAttentionBadge(paperAttentionReason)
                        } else if paperIngestionFailureDetail == nil,
                                  !article.isPaperContentCleanupFailure,
                                  (article.state == .error || article.hasPaywallMarker) {
                            ArticleStateBadge(
                                state: article.state,
                                errorMessage: articleCreditsMessage ?? article.errorMessage,
                                errorLabel: stateBadgeLabel
                            )
                        }
                    }
                }

                if sourcesListLayout == .wide {
                    LibraryRowDetails(
                        article: article,
                        isRowHovered: isHovering,
                        cardState: cardState,
                        makeCards: makeCards,
                        notWorthKeeping: notWorthKeeping
                    )
                }

                if article.isPaperContentCleanupFailure {
                    paperContentCleanupFailureView
                } else if let paperIngestionFailureDetail,
                          let paperIngestionRecoveryAction {
                    paperIngestionFailureView(
                        detail: paperIngestionFailureDetail,
                        recoveryAction: paperIngestionRecoveryAction
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The list's separator starts under the title. Left to itself it
            // starts under the row's last text, a trailing badge's.
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, minHeight: Self.thumbnailSize.height, alignment: .topLeading)
    }

    private var paperContentCleanupFailureView: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .zoomedSystemFont(size: 12, weight: .semibold)
                .foregroundStyle(.orange)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text("Source cleanup couldn't finish")
                    .zoomedSystemFont(size: 11, weight: .semibold)
                Text("Cleanup removes headers, footers, references, and other noise so the paper sounds natural when you listen and uses fewer AI tokens later.")
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = article.paperContentCleanupFailureDetail,
                   !detail.isEmpty {
                    Text(detail)
                        .zoomedSystemFont(size: 10)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Button("Show Log") {
                    showPaperIngestionLog()
                }
                .buttonStyle(.hoverWash)
                .zoomedSystemFont(size: 10, weight: .medium)
                .foregroundStyle(Color.accentColor)
                .help("Reveal the paper ingestion log in Finder")
            }

            Spacer(minLength: 4)

            let recoveryAction = paperIngestionRecoveryAction ?? .retry
            Button(recoveryAction.title) {
                if recoveryAction == .retry {
                    vm.fixPaperContentCleanup(for: article.id)
                } else {
                    fixPaperIngestionFailure(recoveryAction)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("Fix Source Content Cleanup")
            .accessibilityLabel("\(recoveryAction.title) to fix paper source cleanup")
        }
        .padding(8)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    /// Why a paper is in "Papers that need attention": Metadata incomplete
    /// opens its details; PDF needed says so, with Mark as Paywalled beside it
    /// when the AI browser suspects a paywall.
    @ViewBuilder
    private func paperAttentionBadge(_ reason: PaperAttentionReason) -> some View {
        if reason == .metadataIncomplete {
            Button {
                SourceDetailsEditRequest.post(sourceID: article.id, windowID: windowState?.id)
            } label: {
                Label(reason.rawValue, systemImage: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundStyle(rowTint(.orange))
                    .lineLimit(1)
            }
            .buttonStyle(.hoverWash(inset: -3))
            .fixedSize()
            .help("Edit metadata")
            .accessibilityLabel("Metadata incomplete — edit details")
        } else {
            if let suggestedPaywallReason {
                markPaywalledButton(reason: suggestedPaywallReason)
            }
            Label(reason.rawValue, systemImage: "exclamationmark.circle")
                .font(.caption2)
                .foregroundStyle(rowTint(.orange))
                .lineLimit(1)
                .fixedSize()
                .help(reason.rawValue)
                // Selectable text cannot carry its own AX label on
                // macOS; see AGENTS.md, "Text that speaks for itself".
                .textSelection(.disabled)
                .accessibilityLabel(reason.rawValue)
        }
    }

    /// One click does what the AI browser stopped short of: the paper moves to
    /// "Marked paywalled", where a dropped PDF finishes it. The browser's reason
    /// sits in the tooltip so the learner can disagree and leave the row alone.
    private func markPaywalledButton(reason: String) -> some View {
        Button {
            Task { await vm.markPaywalled(article) }
        } label: {
            Label("Mark as Paywalled", systemImage: "lock.doc")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(rowTint(.accentColor))
                .lineLimit(1)
        }
        .fixedSize()
        .buttonStyle(.hoverWash(inset: -3))
        .help("The AI browser thinks this paper is paywalled: \(reason)")
        .accessibilityLabel("Mark as paywalled")
        .accessibilityHint(reason)
    }

    private func paperIngestionFailureView(
        detail: String,
        recoveryAction: PaperIngestionRecoveryAction
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .zoomedSystemFont(size: 12, weight: .semibold)
                .foregroundStyle(.red)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text("Paper ingestion failed")
                    .zoomedSystemFont(size: 11, weight: .semibold)
                Text(detail)
                    .zoomedSystemFont(size: 10)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Show Log") {
                    showPaperIngestionLog()
                }
                .buttonStyle(.hoverWash)
                .zoomedSystemFont(size: 10, weight: .medium)
                .foregroundStyle(Color.accentColor)
                .help("Reveal the paper ingestion log in Finder")
            }

            Spacer(minLength: 4)

            Button(recoveryAction.title) {
                fixPaperIngestionFailure(recoveryAction)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("Fix this paper ingestion failure")
            .accessibilityLabel("\(recoveryAction.title) to fix paper ingestion")
        }
        .padding(8)
        .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    private func fixPaperIngestionFailure(_ action: PaperIngestionRecoveryAction) {
        switch action {
        case .configureAI:
            NotificationCenter.default.post(
                name: .requestOpenStudioSettings,
                object: SettingsPane.aiUsage
            )
        case .addBalance:
            NotificationCenter.default.post(
                name: .requestOpenStudioSettings,
                object: SettingsPane.aiUsage
            )
        case .attachPDF:
            Task {
                let urls = await FilePanel.open { panel in
                    panel.allowedContentTypes = [.pdf]
                    panel.message = "Select a readable PDF for this paper"
                }
                guard let url = urls.first else { return }
                do {
                    try await vm.attachPDF(to: article.id, pdfURL: url)
                } catch {
                    vm.showToast("Could not attach PDF: \(error.localizedDescription)")
                }
            }
        case .editDetails:
            SourceDetailsEditRequest.post(sourceID: article.id, windowID: windowState?.id)
        case .retry:
            Task { await vm.extractPaperMetadataWithAI(id: article.id) }
        }
    }

    private func showPaperIngestionLog() {
        Task {
            guard let url = await PaperIngestionDiagnostics.logURLRecordingCurrentFailure(
                sourceID: article.id,
                title: article.title,
                message: article.errorMessage ?? "No failure details were recorded."
            ) else {
                vm.showToast("Could not open the paper ingestion log")
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    @ViewBuilder
    private var sourceThumbnailView: some View {
        // Artwork thumbnail, local document preview, or SF Symbol fallback
        if let thumbnailPath = localDocumentThumbnailPath {
            BookCoverThumbnail(
                pdfPath: thumbnailPath,
                size: Self.thumbnailSize,
                placeholderSystemImage: sourceTypeIcon(article.sourceType),
                tint: sourceTypeColor(article.sourceType)
            )
        } else if let artworkURLString = article.artworkURL,
                  MeetingIconService.localArtworkPath(for: artworkURLString) == nil,
                  let artworkURL = URL(string: artworkURLString) {
            CachedAsyncImage(url: artworkURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .failure:
                    sourceTypeIconView
                default:
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary)
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            sourceTypeIconView
        }
    }

    @ViewBuilder
    private var sourceTypeIconView: some View {
        if article.sourceType == .xPost {
            XLogoShape()
                .fill(sourceTypeColor(article.sourceType), style: FillStyle(eoFill: true))
                .frame(width: 18, height: 18)
                .frame(width: 36, height: 36)
        } else if ZoomRecordingService.isZoomRecordingURL(article.url) {
            Image("ZoomIcon")
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: 20, height: 20)
                .frame(width: 36, height: 36)
        } else {
            Image(systemName: sourceTypeIcon(article.sourceType))
                .zoomedSystemFont(size: 20)
                .foregroundStyle(sourceTypeColor(article.sourceType))
                .frame(width: 36, height: 36)
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

// MARK: - What a source row says

extension StudioViewModel {
    /// The title a source row prints: a meeting session's row title, and a
    /// book chapter's, course lesson's or playlist video's own title without
    /// the group name its header already shows.
    func sourceRowTitle(for article: StudioArticle) -> String {
        if article.sourceType == .meeting { return meetingRowTitle(for: article).text }
        let baseTitle = displayTitle(for: article)
        if let group = article.parentGroup,
           (article.sourceType == .book || article.sourceType == .course || article.sourceType == .video) {
            let groupTitle = article.sourceType == .book ? bookDisplayName(group) : group
            guard baseTitle.hasPrefix(groupTitle) else { return baseTitle }
            let stripped = baseTitle.dropFirst(groupTitle.count)
            // Remove separator like " – " or " - "
            let trimmed = stripped.drop(while: { $0 == " " || $0 == "–" || $0 == "-" || $0 == "—" })
            if !trimmed.isEmpty {
                return String(trimmed)
            }
        }
        return baseTitle
    }

    /// A meeting session's row title, and the day it stands for when the
    /// title is nothing but a date. One helper names every session the same
    /// way however its title was stored.
    func meetingRowTitle(for article: StudioArticle) -> MeetingSessionRowTitle {
        Self.meetingSessionRowTitle(
            storedTitle: displayTitle(for: article),
            groupTitle: article.parentGroup.map { meetingDisplayName($0) } ?? "",
            dateAdded: article.dateAdded
        )
    }

    /// A session's title in a list that mixes series: its series' name, then
    /// the session's own name when it has one besides its day, which the
    /// metadata line prints instead (`meetingSessionWhen`).
    func meetingSeriesRowTitle(for article: StudioArticle) -> String {
        let row = meetingRowTitle(for: article)
        let series = article.parentGroup.map { meetingDisplayName($0) } ?? ""
        guard !series.isEmpty else { return row.text }
        return row.day != nil ? series : "\(series) — \(row.text)"
    }

    /// The title a source carries where nothing around it names its group: the
    /// reader's header. A meeting session is stored under its own name, often
    /// nothing but its day, so on its own it read "2026/10/25" with no word of
    /// which series it was (product owner, 2026-11-07: "it would be nice if these
    /// videos … also have like [the group's name] in the title"). It reads
    /// "<series> — <day or topic>" instead.
    func standaloneTitle(for article: StudioArticle) -> String {
        guard article.sourceType == .meeting else { return displayTitle(for: article) }
        let row = meetingRowTitle(for: article)
        let series = article.parentGroup.map { meetingDisplayName($0) } ?? ""
        guard !series.isEmpty, series != row.text else { return row.text }
        return "\(series) — \(row.text)"
    }

    /// When a session happened, for a list that mixes series: the day it stands
    /// for, with the time when one is known, and no midnight made up when none is.
    func meetingSessionWhen(for article: StudioArticle) -> String {
        let row = meetingRowTitle(for: article)
        guard row.day != nil else {
            return article.dateAdded.formatted(date: .abbreviated, time: .shortened)
        }
        if let time = row.time {
            return time.formatted(date: .abbreviated, time: .shortened)
        }
        return (row.day ?? article.dateAdded).formatted(date: .abbreviated, time: .omitted)
    }

    /// What a notebook's source row says beside its spinner. A paper whose PDF
    /// is already attached opens and reads, so its row does not spin while the
    /// background text and metadata passes still queue behind it; only a source
    /// with nothing to open yet spins.
    func notebookRowActivityLabel(for article: StudioArticle) -> String? {
        if article.sourceType == .paper,
           article.state != .fetching,
           displayHasUsablePDF(article) {
            return nil
        }
        return sourceRowActivityLabel(for: article)
    }

    /// What a source row says beside its spinner while the source's content
    /// is on its way — a fetch, a transcript, a PDF being attached, a paper's
    /// processing step — and nil while nothing is.
    func sourceRowActivityLabel(for article: StudioArticle) -> String? {
        let paperStep = paperProcessingStepLabel(for: article)
        let isAttachingPDF = attachingPDFIds.contains(article.id)
        let isYouTubeProcessing = article.sourceType == .video
            && YouTubeTranscriptService.isYouTubeURL(article.url)
            && (article.state == .queued
                || article.state == .fetching
                || youtubeTranscriptFetchInFlight.contains(article.id))
        let isActive = article.state == .fetching
            || (article.sourceType == .podcast && article.state == .queued)
            || isYouTubeProcessing
            || isAttachingPDF
            || paperStep != nil
        guard isActive else { return nil }
        // The attaching marker stays set through the whole ingestion pipeline
        // so the row never leaves Processing. The view model publishes the real
        // phase underneath it, so a published phase wins; "Attaching PDF…" is
        // only the fallback for the brief copy-and-persist window before one.
        if let paperStep { return paperStep }
        if isAttachingPDF { return "Attaching PDF…" }
        switch article.sourceType {
        case .podcast:
            return article.state == .queued ? "Queued for transcript…" : "Getting transcript…"
        case .paper:
            return "Loading paper…"
        case .course:
            return "Loading file…"
        case .video:
            if article.state == .queued { return "Waiting to process…" }
            if article.state == .ready && youtubeTranscriptFetchInFlight.contains(article.id) {
                return "Formatting transcript…"
            }
            return "Fetching transcript…"
        case .meeting:
            if article.state == .queued, ZoomRecordingService.isZoomRecordingURL(article.url) {
                return article.errorMessage ?? "Waiting for Zoom's transcript…"
            }
            return "Fetching transcript…"
        default:
            return "Fetching content…"
        }
    }
}

/// A source row's read state, at the row's trailing edge. Read's closed book
/// and Listened's headphones stay drawn, in the row's grey; Unread's empty
/// circle shows only while the pointer is over the row or the row is
/// selected, since a column of empty circles down every unread row was noise
/// (product owner, 2026-10-06, "kind of like the chatgpt app"; "Lists are
/// monochrome", docs/ui-design.md). An unread title already reads in the
/// primary colour, a read one in grey. The slot keeps its size either way, so
/// the column stays aligned, and the button around it keeps its click,
/// tooltip and accessibility label.
///
/// A view of its own so that only this mark, and only on an unread row the
/// pointer is not over, reads the window's selection: a click in the list
/// never re-runs the rows around it.
private struct SourceReadStateMark: View {
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?
    let sourceID: String
    let status: SourceConsumptionStatus
    let isRowHovered: Bool

    private var isShown: Bool {
        status != .unread
            || isRowHovered
            || windowState?.sidebarSelectedSourceIDs.contains(sourceID) == true
    }

    var body: some View {
        Image(systemName: status.icon)
            .zoomedSystemFont(size: 12, weight: .medium)
            .foregroundStyle(isShown ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.clear))
            .frame(width: 18, height: 18)
            .contentShape(Circle())
    }
}

/// YouTube-style watched sliver along the bottom edge of a video thumbnail.
struct VideoWatchProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(0.35))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(3, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 3)
        .padding(.horizontal, 3)
        .padding(.bottom, 3)
        .allowsHitTesting(false)
    }
}

struct PaperPDFDropTargetModifier: ViewModifier {
    @Environment(StudioViewModel.self) private var vm
    let article: StudioArticle
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .overlay {
                // Mounted only while a file drag hovers the row (Finder drags
                // never set StudioDragVisibility, so `isTargeted` is the only
                // signal). At rest the overlay's animatable stroke would
                // otherwise cost attribute nodes on every visible source row.
                if isTargeted {
                    StudioDropZoneOverlay(
                        isActive: isTargeted,
                        title: article.sourceType == .paper ? "Attach to this paper" : "Attach PDF",
                        systemImage: "doc.badge.plus",
                        cornerRadius: 8,
                        inset: 0
                    )
                }
            }
            .onDrop(of: [.fileURL, .pdf], isTargeted: $isTargeted, perform: handleDrop)
            .dropTargetWatchdog($isTargeted)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
                    if let error {
                        Task { @MainActor in
                            vm.showToast("Could not read dropped PDF: \(error.localizedDescription)")
                        }
                        return
                    }
                    let url: URL?
                    if let data = data as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else if let nsURL = data as? NSURL {
                        url = nsURL as URL
                    } else {
                        url = data as? URL
                    }
                    guard let url, url.pathExtension.lowercased() == "pdf" else { return }
                    attachDroppedPDF(url)
                }
                continue
            }

            guard provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) else { continue }
            handled = true
            provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { url, error in
                if let error {
                    Task { @MainActor in
                        vm.showToast("Could not read dropped PDF: \(error.localizedDescription)")
                    }
                    return
                }
                guard let url else { return }
                do {
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("ForeverLM-Dropped-\(UUID().uuidString).pdf")
                    try? FileManager.default.removeItem(at: tempURL)
                    try FileManager.default.copyItem(at: url, to: tempURL)
                    Task { @MainActor in
                        attachDroppedPDF(tempURL, removeAfterAttach: true)
                    }
                } catch {
                    Task { @MainActor in
                        vm.showToast("Could not copy dropped PDF: \(error.localizedDescription)")
                    }
                }
            }
        }
        return handled
    }

    private func attachDroppedPDF(_ url: URL, removeAfterAttach: Bool = false) {
        Task { @MainActor in
            defer {
                if removeAfterAttach {
                    Task.detached(priority: .utility) {
                        try? FileManager.default.removeItem(at: url)
                    }
                }
            }
            do {
                try await vm.attachPDF(to: article.id, pdfURL: url)
            } catch {
                vm.showToast("Could not attach PDF: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Metadata Visibility Popover

struct MetadataVisibilityPopover: View {
    let tab: StudioSidebarTab
    @Binding var settings: MetadataVisibilitySettings
    // Books: filter by category
    var selectedBookKind: Binding<String?>?
    var allBookKinds: [String] = []
    private var sourceType: StudioSourceType? { tab.sourceType }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Show in \(tab.rawValue)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)

            if let type = sourceType {
                let fields = type.configurableMetadataFields
                ForEach(fields, id: \.self) { field in
                    Toggle(isOn: Binding(
                        get: { settings.isVisible(field, for: type) },
                        set: { _ in settings.toggle(field, for: type) }
                    )) {
                        Label(field.displayName(for: type), systemImage: field.icon(for: type))
                            .font(.subheadline)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                }

            }

            if let binding = selectedBookKind, !allBookKinds.isEmpty {
                Divider()
                    .padding(.vertical, 6)
                Picker(selection: binding) {
                    Text("All").tag(String?.none)
                    ForEach(allBookKinds, id: \.self) { kind in
                        Text(kind).tag(Optional(kind))
                    }
                } label: {
                    Label("Category", systemImage: "tag")
                        .font(.subheadline)
                }
                .pickerStyle(.menu)
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
            }

        }
        .padding(.bottom, 10)
        .frame(width: 220)
    }
}
