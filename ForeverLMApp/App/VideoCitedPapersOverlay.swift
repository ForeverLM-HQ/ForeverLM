import AppKit
import SwiftUI

// MARK: - Shared surface

/// Shape, fill and spacing shared by the transcript's card and the full list, so the two
/// read as one feature seen at two sizes rather than two panels that happen to list papers.
private enum CitedPaperStyle {
    static let rowCornerRadius: CGFloat = 9

    /// Fill behind the small inline pills — timestamps, section counts, the in-library marker.
    static let pillFill = Color.primary.opacity(0.07)

    /// Fill behind the card set into the transcript margin. Fainter than `pillFill` on
    /// purpose: this one sits in the reading column rather than on top of it, and a panel
    /// solid enough to read as a control would interrupt the transcript around it.
    static let marginFill = Color.primary.opacity(0.035)

    static let hairline = Color.primary.opacity(0.10)
}

// MARK: - Controls

/// The one action either surface exists for, so it is the only thing in a row carrying the
/// accent colour. Everything beside it — dismiss, restore, jump-to-slide — stays grey, which
/// is what makes Add findable without the row shouting.
private struct CitedPaperAddButton: View {
    var title: String = "Add"
    /// Type size, which the capsule's padding follows so the pill keeps its proportions
    /// wherever it is used — the transcript margin runs a size down from the popups.
    var size: CGFloat = 11
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, size - 1)
                .padding(.vertical, size / 3)
                .background(Color.accentColor.opacity(isHovered ? 1 : 0.88), in: Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .cursor(.pointingHand)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help("Add this paper to your library")
    }
}

/// The action on a paper that came back with no matching record: look it up again, this
/// time spending on the one row. Takes the accent for the same reason Add does — on an
/// unmatched row it is the one thing to do — and holds its own progress, so a card or list
/// with several unmatched rows shows which one is searching.
private struct CitedPaperFindButton: View {
    var size: CGFloat = 11
    let action: @MainActor () async -> Void

    @State private var isFinding = false
    @State private var isHovered = false

    var body: some View {
        if isFinding {
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                Text("Searching…")
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, size / 3)
        } else {
            Button {
                isFinding = true
                Task {
                    await action()
                    isFinding = false
                }
            } label: {
                Label("Find", systemImage: "magnifyingglass")
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, size - 1)
                    .padding(.vertical, size / 3)
                    .background(Color.accentColor.opacity(isHovered ? 1 : 0.88), in: Capsule())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .cursor(.pointingHand)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .help("Read the slide again and search the catalogs and the web for this paper")
        }
    }
}

/// Grey text action — dismiss, restore. Bordered controls at this size crowd a row with
/// chrome that competes with the paper title for attention.
private struct CitedPaperQuietButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.hoverWash(cornerRadius: 6, inset: -5, opacity: 0.10))
        .cursor(.pointingHand)
    }
}

/// Small round icon button for a row's dismiss.
private struct CitedPaperIconButton: View {
    let systemImage: String
    var size: CGFloat = 10
    var diameter: CGFloat = 20
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: diameter, height: diameter)
        }
        .buttonStyle(.hoverWash(in: Circle(), inset: 0, opacity: 0.12))
        .cursor(.pointingHand)
    }
}

/// Marker for a paper the library already holds. Deliberately not a button: there is nothing
/// to add and nothing to wave off, so it states the fact and takes no click.
private struct CitedPaperLibraryBadge: View {
    var body: some View {
        Label("In library", systemImage: "checkmark")
            .labelStyle(.titleAndIcon)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(CitedPaperStyle.pillFill, in: Capsule())
            .help("Already in your library")
    }
}

/// Timestamp of the slide a candidate was read off, as a jump control.
private struct CitedPaperTimestampButton: View {
    let seconds: Double
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(YouTubeTranscriptTime.display(seconds), systemImage: "play.fill")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(CitedPaperStyle.pillFill, in: Capsule())
        }
        .buttonStyle(.hoverWash(in: Capsule(), inset: 0, opacity: 0.10))
        .cursor(.pointingHand)
        .help("Jump to the slide this came from")
    }
}

// MARK: - Row pieces

/// The slide frame a candidate was read off, at row size.
///
/// The frame is the evidence for the suggestion. Seeing it beside the title is what makes a
/// wrong match obvious at a glance — a dairy science proceedings next to a slide about the
/// free radical theory of aging reads as wrong instantly, where the title alone does not.
private struct CitedPaperSlideThumb: View {
    let imagePath: String?
    /// Whether clicking seeks the video, which decides if the thumb offers a play affordance.
    var canSeek: Bool = false

    @State private var image: NSImage?
    @State private var didLoad = false
    @State private var isHovered = false

    private static let width: CGFloat = 78

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(didLoad ? 0.06 : 0.12))
                    .overlay {
                        if didLoad {
                            Image(systemName: "photo")
                                .font(.system(size: 13))
                                .foregroundStyle(.tertiary)
                        }
                    }
            }
        }
        .frame(width: Self.width, height: Self.width * 9 / 16)
        .clipShape(shape)
        .overlay {
            if canSeek, isHovered {
                ZStack {
                    shape.fill(Color.black.opacity(0.38))
                    Image(systemName: "play.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                }
            }
        }
        .overlay {
            shape.strokeBorder(Color.primary.opacity(isHovered && canSeek ? 0.30 : 0.12))
        }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .task(id: imagePath) {
            guard let imagePath else {
                didLoad = true
                return
            }
            // The KB lives in iCloud Drive, so both path resolution and the decode stay off
            // the main actor: an evicted frame blocks until CloudDocs fetches it.
            image = await Task.detached(priority: .utility) {
                SlideMarginThumb.loadThumbnail(path: imagePath, maxPixel: 220)
            }.value
            didLoad = true
        }
        // The frame was not on this Mac and has just been captured again.
        .onReceive(NotificationCenter.default.publisher(for: SlideFrameRestorer.framesRestored)) { _ in
            guard image == nil, let imagePath else { return }
            Task {
                image = await Task.detached(priority: .utility) {
                    SlideMarginThumb.loadThumbnail(path: imagePath, maxPixel: 220)
                }.value
            }
        }
    }
}

/// A candidate's title, opening the paper when it resolved to one.
///
/// An unresolved candidate has no URL, so it stays plain text rather than presenting a
/// link that would go nowhere.
private struct CitedPaperTitle: View {
    let paper: VideoCitedPaper
    var font: Font = .system(size: 13, weight: .medium)

    @Environment(\.openURL) private var openURL
    @State private var isHovered = false

    private var url: URL? {
        paper.url.flatMap { URL(string: $0) }
    }

    /// Titles truncate everywhere they are shown, so the tooltip always carries the whole
    /// one; the link destination is appended to it rather than replacing it.
    private var helpText: String {
        guard let url else { return paper.title }
        return "\(paper.title)\n\nOpen \(url.absoluteString)"
    }

    private var label: some View {
        Text(paper.title)
            .font(font)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        if let url {
            Button {
                openURL(url)
            } label: {
                label.underline(isHovered)
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: -3))
            .onHover { isHovered = $0 }
            .cursor(.pointingHand)
            .help(helpText)
        } else {
            label.help(helpText)
        }
    }
}

/// Ties each cited paper to the slide it was read from.
///
/// The tie is the stored frame path, recorded at extraction, and it is what lets the
/// transcript print a citation against the frame it was printed on rather than only in a
/// list elsewhere.
enum VideoCitedPaperWindow {
    /// Papers grouped under the slide each was read from, keyed by slide index.
    ///
    /// Every slide answers for itself, with no reference to playback: the transcript gets
    /// read at least as often as the video gets watched, and a citation is no less true
    /// when nothing is playing. Dismissed rows stay out, since that decision was already
    /// made. Unresolved ones stay in, because a lookup that failed is not a slide that cited
    /// nothing, and here there is room to say so. A paper that matches no slide has nothing
    /// to sit under and is left to the Papers list.
    static func bySlide(
        papers: [VideoCitedPaper],
        slides: [YouTubeSlideFrameContext]
    ) -> [Int: [VideoCitedPaper]] {
        let shown = papers.filter { $0.status != .dismissed }
        guard !shown.isEmpty, !slides.isEmpty else { return [:] }

        // Indexed once rather than scanned per paper: the transcript re-renders on every
        // playback tick, and the frame path is how all but the oldest rows resolve.
        var slideIndexesByPath: [String: Int] = [:]
        for slide in slides { slideIndexesByPath[slide.imagePath] = slide.index }

        var result: [Int: [VideoCitedPaper]] = [:]
        for paper in shown {
            let index = paper.slideImagePath.flatMap { slideIndexesByPath[$0] }
                ?? slide(for: paper, in: slides)?.index
            guard let index else { continue }
            result[index, default: []].append(paper)
        }
        return result
    }

    /// The slide a paper was read from. The stored frame path is the identity — timestamps
    /// resolve only to the storyboard's tile interval, so two slides can round onto the same
    /// one — with a timestamp match as the fallback for rows saved before paths were kept.
    static func slide(
        for paper: VideoCitedPaper,
        in slides: [YouTubeSlideFrameContext]
    ) -> YouTubeSlideFrameContext? {
        if let path = paper.slideImagePath,
           let matched = slides.first(where: { $0.imagePath == path }) {
            return matched
        }
        guard let seconds = paper.slideTimeSeconds else { return nil }
        return slides.first { slide in
            guard let slideSeconds = slide.timeSeconds else { return false }
            return abs(slideSeconds - seconds) < 0.5
        }
    }
}

/// The papers read off one slide, listed under its thumbnail in the transcript.
///
/// The only place a slide's citations are offered. They do not float over the video in
/// a chip keyed to playback: that puts a panel on top of the slide being read and takes
/// the suggestion away the moment the talk cuts to the next frame. Against the frame it
/// was printed on, a citation is visible without playback, actionable without leaving the
/// page, and still there when the reader scrolls back to it.
///
/// Set into the reading column — 200pt in the wide layout's gutter, and in the inline layout
/// beside the frame when the column can hold both or under it when it cannot — it carries no
/// slide thumbnail, because the frame it was read off is immediately next to it.
///
/// The card is what says these belong to that frame. Loose under a slide, a title and an Add
/// button read as debris in the transcript; bounded, they read as the frame's citation.
struct SlideCitedPapersColumn: View {
    let papers: [VideoCitedPaper]
    let onImport: ((VideoCitedPaper) -> Void)?
    let onDismiss: ((VideoCitedPaper) -> Void)?
    /// Looks an unmatched paper up again. Nil where nothing can run the lookup.
    var onFind: (@MainActor (VideoCitedPaper) async -> Void)? = nil

    /// Ordered by how much there is to do about each: still on offer, already held, then
    /// the ones that resolved to nothing. Partitioned rather than sorted because
    /// `sorted(by:)` is not stable, and these rows re-render on every playback tick.
    private var ordered: [VideoCitedPaper] {
        papers.filter { $0.status == .pending }
            + papers.filter { $0.status == .imported }
            + papers.filter { $0.status == .unresolved }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: CitedPaperStyle.rowCornerRadius, style: .continuous)
    }

    var body: some View {
        if !papers.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                header

                ForEach(Array(ordered.enumerated()), id: \.element.id) { index, paper in
                    if index > 0 {
                        Divider()
                            .overlay(CitedPaperStyle.hairline)
                            .padding(.leading, Self.inset)
                    }
                    row(paper)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CitedPaperStyle.marginFill, in: shape)
            .overlay { shape.strokeBorder(CitedPaperStyle.hairline) }
        }
    }

    private static let inset: CGFloat = 9

    /// Names what the card is, which nothing else here does — the full list says it in a
    /// header, and in the transcript an unlabelled title over an Add button gives the reader
    /// no way to tell a citation from anything else the app might be offering.
    ///
    /// Its icon stays grey rather than taking the accent it has in the list: Add is the one
    /// thing in this card worth colouring, and at margin scale two accents is one too many.
    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 9, weight: .semibold))

            Text(papers.count == 1 ? "Cited paper" : "\(papers.count) cited papers")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.4)
                .textCase(.uppercase)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, Self.inset)
        .padding(.top, 7)
    }

    /// Flush left, all of it. The old row hung the title off a leading document icon and then
    /// pushed the subtitle and buttons back under it by a hardcoded inset; the header carries
    /// that icon for the whole card now, so the column has one edge instead of two.
    private func row(_ paper: VideoCitedPaper) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            CitedPaperTitle(paper: paper, font: .system(size: 12, weight: .medium))
                .lineLimit(3)

            if let subtitle = paper.displaySubtitle {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            actions(paper)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Self.inset)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private func actions(_ paper: VideoCitedPaper) -> some View {
        switch paper.status {
        case .pending:
            HStack(spacing: 4) {
                if let onImport {
                    CitedPaperAddButton(size: 10) { onImport(paper) }
                }
                if let onDismiss {
                    dismissButton(paper, action: onDismiss)
                }
            }
        case .imported:
            CitedPaperLibraryBadge()
        case .unresolved:
            // Said out loud rather than hidden: the slide did cite something, and the row
            // exists so a failed lookup never reads as an absent citation — nor as the end
            // of the road, since Find looks again.
            HStack(spacing: 4) {
                if let onFind, paper.kind == .paper {
                    CitedPaperFindButton(size: 10) { await onFind(paper) }
                }
                Text("No matching record")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                if let onDismiss {
                    dismissButton(paper, action: onDismiss)
                }
            }
        case .dismissed:
            // Filtered out upstream; a waved-off paper has no row here.
            EmptyView()
        }
    }

    private func dismissButton(
        _ paper: VideoCitedPaper,
        action: @escaping (VideoCitedPaper) -> Void
    ) -> some View {
        CitedPaperIconButton(systemImage: "xmark", size: 9, diameter: 18) {
            action(paper)
        }
        .help("Don't suggest this paper")
    }
}

/// The action that fills or refreshes a cited-papers list, offered from the list itself
/// so an empty list is one click from having its papers.
struct CitedPaperScanAction {
    let title: String
    let isRunning: Bool
    let action: () -> Void
}

/// Every paper found across a source, including the ones that could not be resolved and
/// the ones already waved off.
///
/// Videos and meetings show the slide frame each candidate was read off beside its row,
/// with a jump to that moment; a paper's reference list has no such evidence, and
/// `showsSlideEvidence` leaves the frame and the timestamp out for it.
struct VideoCitedPapersList: View {
    let papers: [VideoCitedPaper]
    let onImport: (VideoCitedPaper) -> Void
    let onDismiss: (VideoCitedPaper) -> Void
    let onRestore: (VideoCitedPaper) -> Void
    /// Looks an unmatched paper up again. Nil where nothing can run the lookup.
    let onFind: (@MainActor (VideoCitedPaper) async -> Void)?
    let title: String
    let emptyMessage: String
    let showsSlideEvidence: Bool
    /// The heading over the candidates still waiting on the learner: "Cited papers" for the
    /// paper reads, "Linked sources" for an article's links.
    let pendingSectionTitle: String
    let scanAction: CitedPaperScanAction?
    /// What the scan is doing or did, shown under the header. The paper reader passes its
    /// reference read's report so progress and the outcome appear where the learner clicked,
    /// not as a toast at the bottom of the window; the video readers pass nothing and keep
    /// the header's spinner.
    let report: CitedPaperScanReport?
    let onSeek: (Double) -> Void

    init(
        papers: [VideoCitedPaper],
        onImport: @escaping (VideoCitedPaper) -> Void,
        onDismiss: @escaping (VideoCitedPaper) -> Void,
        onRestore: @escaping (VideoCitedPaper) -> Void,
        onFind: (@MainActor (VideoCitedPaper) async -> Void)? = nil,
        title: String = "Papers cited in this video",
        emptyMessage: String = "No papers were found on this video's slides.",
        showsSlideEvidence: Bool = true,
        pendingSectionTitle: String = "Cited papers",
        scanAction: CitedPaperScanAction? = nil,
        report: CitedPaperScanReport? = nil,
        onSeek: @escaping (Double) -> Void = { _ in }
    ) {
        self.papers = papers
        self.onImport = onImport
        self.onDismiss = onDismiss
        self.onRestore = onRestore
        self.onFind = onFind
        self.title = title
        self.emptyMessage = emptyMessage
        self.showsSlideEvidence = showsSlideEvidence
        self.pendingSectionTitle = pendingSectionTitle
        self.scanAction = scanAction
        self.report = report
        self.onSeek = onSeek
    }

    private var pending: [VideoCitedPaper] { papers.filter { $0.status == .pending } }
    private var unresolved: [VideoCitedPaper] { papers.filter { $0.status == .unresolved } }
    private var imported: [VideoCitedPaper] { papers.filter { $0.status == .imported } }
    private var dismissed: [VideoCitedPaper] { papers.filter { $0.status == .dismissed } }

    var body: some View {
        VStack(spacing: 0) {
            header

            if let report {
                reportLine(report)
            }

            Divider().overlay(CitedPaperStyle.hairline)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if papers.isEmpty {
                        emptyState
                    }

                    section(pendingSectionTitle, pending) { paper in
                        CitedPaperAddButton(title: "Add to Library") { onImport(paper) }
                        CitedPaperQuietButton(title: "Dismiss") { onDismiss(paper) }
                    }

                    // Shown rather than hidden: a lookup that failed is not the same as a slide
                    // that cited nothing, and Find looks again, harder, for the one row.
                    section("Couldn't be matched", unresolved) { paper in
                        if let onFind, paper.kind == .paper {
                            CitedPaperFindButton { await onFind(paper) }
                        }
                        Label("No matching record", systemImage: "questionmark.circle")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(CitedPaperStyle.pillFill, in: Capsule())
                        CitedPaperQuietButton(title: "Dismiss") { onDismiss(paper) }
                    }

                    // Covers both papers imported from here and papers the library already held
                    // when the video was scanned — from the learner's side they are the same
                    // thing, and neither should be offered for import.
                    section("Already in your library", imported) { _ in
                        CitedPaperLibraryBadge()
                    }

                    // Dimmed so a scan of the list reads straight past them: these are
                    // decisions already made, kept only so they can be undone.
                    section("Dismissed", dismissed, dimmed: true) { paper in
                        CitedPaperQuietButton(title: "Restore") { onRestore(paper) }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
            }
        }
        .frame(width: 520, height: 500)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            Text(title)
                .font(.system(size: 13, weight: .semibold))

            Spacer(minLength: 8)

            if !papers.isEmpty {
                Text("\(papers.count)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(CitedPaperStyle.pillFill, in: Capsule())
            }

            // The refresh lives up here once the list has rows; the empty state carries
            // the same action as its one button. While a scan runs, the report line below
            // carries the spinner when there is one, so it is not shown twice.
            if let scanAction, !papers.isEmpty {
                if scanAction.isRunning {
                    if report == nil {
                        ProgressView()
                            .controlSize(.small)
                    }
                } else {
                    CitedPaperQuietButton(title: scanAction.title, action: scanAction.action)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    /// The scan's progress or outcome, in the header where the scan was started from.
    private func reportLine(_ report: CitedPaperScanReport) -> some View {
        HStack(spacing: 7) {
            switch report.phase {
            case .running:
                ProgressView()
                    .controlSize(.mini)
            case .finished:
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
            }

            Text(report.message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 9)
        .accessibilityIdentifier("citedPapers.report")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(emptyMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let scanAction {
                if scanAction.isRunning {
                    if report == nil {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.top, 6)
                    }
                } else {
                    CitedPaperAddButton(title: scanAction.title, size: 12, action: scanAction.action)
                        .padding(.top, 6)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 90)
    }

    @ViewBuilder
    private func section(
        _ title: String,
        _ items: [VideoCitedPaper],
        dimmed: Bool = false,
        @ViewBuilder actions: @escaping (VideoCitedPaper) -> some View
    ) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.4)
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)

                    Text("\(items.count)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(CitedPaperStyle.pillFill, in: Capsule())
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 4)

                ForEach(items) { paper in
                    row(paper, actions: actions(paper))
                        .opacity(dimmed ? 0.62 : 1)
                }
            }
        }
    }

    /// Rows here span the whole video, so the frame each candidate came off is genuinely
    /// distinguishing — and it is the evidence for the match.
    private func row(_ paper: VideoCitedPaper, actions: some View) -> some View {
        HStack(alignment: .top, spacing: 11) {
            if showsSlideEvidence {
                Button {
                    if let seconds = paper.slideTimeSeconds { onSeek(seconds) }
                } label: {
                    CitedPaperSlideThumb(
                        imagePath: paper.slideImagePath,
                        canSeek: paper.slideTimeSeconds != nil
                    )
                }
                .buttonStyle(.plain)
                .disabled(paper.slideTimeSeconds == nil)
                .cursor(paper.slideTimeSeconds == nil ? .arrow : .pointingHand)
                .help("Jump to the slide this came from")
            }

            VStack(alignment: .leading, spacing: 3) {
                CitedPaperTitle(paper: paper)
                    .lineLimit(3)

                if let subtitle = paper.displaySubtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                // What the article says about a linked source, so it can be judged without
                // opening it. The paper kinds carry no such line; their fields say enough.
                if let context = paper.context, !context.isEmpty {
                    Text(context)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 1)
                }

                HStack(spacing: 8) {
                    if showsSlideEvidence, let seconds = paper.slideTimeSeconds {
                        CitedPaperTimestampButton(seconds: seconds) { onSeek(seconds) }
                    }
                    actions
                }
                .padding(.top, 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        // Inset 0: the default grows the wash past the row, and stacked rows would then
        // light up each other's neighbours.
        .hoverHighlight(cornerRadius: CitedPaperStyle.rowCornerRadius, inset: 0, opacity: 0.05)
    }
}
