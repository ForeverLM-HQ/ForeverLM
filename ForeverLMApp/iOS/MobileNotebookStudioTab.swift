import AVFoundation
import SwiftUI

/// A notebook's Studio on the phone, drawn as the Mac's Studio column is
/// (`NotebookStudioColumn`): the things the phone can make from the
/// notebook's sources as labelled chips in two columns
/// (`MobileNotebookStudioTile`: Explainer, Walkthrough, Quiz), then
/// what was made, under no heading — the Cards row and its Practice first,
/// what is being written, and everything made from it, each row its kind's
/// glyph, its title and the Mac's "Doc · 4 sources · 3 days ago"
/// (`MobileNotebookOutputLine`). Each
/// opens here: audio overviews and explainers play, Docs (reports among them) read, walkthroughs deal their cards,
/// linked courses open their page. What it lists and in what order are the
/// Mac's Studio's rules (`NotebookOutputs`): the Docs and audio overviews
/// filed in it, the courses it follows, the walkthroughs and explainers of
/// its own sources, newest first by when each was made. Making a Doc, a
/// report, cards or an audio overview stays on the Mac for now.
struct MobileNotebookStudioTab: View {
    let notebook: MobileCloudNotebook

    @EnvironmentObject private var vm: MobileAudioReviewViewModel
    @ObservedObject private var explainers = MobileExplainerGenerator.shared
    @ObservedObject private var walkthroughs = MobileWalkthroughGenerator.shared
    @State private var walkthroughToPlay: MobileNotebookWalkthrough?
    /// "42 kept · 6 due"; nil until counted.
    @State private var cardCounts: NotebookCardCounts?
    /// A notice's glyph column, as wide as the output rows' beside it.
    @ScaledMetric(relativeTo: .body) private var noticeGlyphWidth: CGFloat = 24

    /// The notebook's own sources — its Sources tab — which its walkthroughs
    /// and explainers ride and the make buttons offer: a context notebook's
    /// reach its chats alone, and only while it is put in, never what its
    /// Studio makes.
    private var ownSources: [MobileCloudSource] {
        vm.notebookOwnSources(in: notebook)
    }

    var body: some View {
        List {
            Section {
                tiles
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            }
            // What was made, under no heading, and nothing at all while
            // nothing is (2026-10-06, as the Mac's Studio: the tiles say what
            // can be made; it said "Outputs" and "Nothing made yet").
            Section {
                // The Mac's Studio shows no Cards row for a notebook with no
                // card (`NotebookCardCounts.isEmpty`), and leads its outputs
                // with it otherwise: a card rides its source, not the notebook.
                if let counts = cardCounts.flatMap({ $0.isEmpty ? nil : $0 }) {
                    cardsRow(counts)
                }
                ForEach(writingExplainers) { source in
                    MobileStudioOutputRow(
                        systemImage: MobileNotebookOutputGlyph.explainer,
                        title: source.title,
                        line: "Writing explainer…",
                        isBusy: true
                    )
                }
                ForEach(writingWalkthroughs) { source in
                    MobileStudioOutputRow(
                        systemImage: MobileNotebookOutputGlyph.walkthrough,
                        title: source.title,
                        line: "Writing walkthrough…",
                        isBusy: true
                    )
                }
                ForEach(walkthroughNotices, id: \.source.id) { notice in
                    noticeRow(notice.source, message: notice.message)
                }
                ForEach(outputs) { output in
                    outputRow(output)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await vm.load() }
        .task(id: cardsKey) {
            cardCounts = await vm.notebookCardCounts(in: notebook)
        }
        .fullScreenCover(item: $walkthroughToPlay) { walk in
            MobileWalkthroughDeckView(source: walk.source, deck: walk.deck, notebook: notebook)
        }
    }

    // MARK: - Make

    /// The Mac's grid of chips: two columns, in the tiles' order.
    private var tiles: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: MobileDesign.Spacing.small),
                GridItem(.flexible(), spacing: MobileDesign.Spacing.small),
            ],
            spacing: MobileDesign.Spacing.small
        ) {
            ForEach(MobileNotebookStudioTile.allCases) { tile in
                tileControl(tile)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Make")
        .accessibilityIdentifier("notebook.studio.tiles")
    }

    @ViewBuilder
    private func tileControl(_ tile: MobileNotebookStudioTile) -> some View {
        switch tile {
        case .explainer:
            Menu {
                let explainable = ownSources.filter {
                    MobileExplainerStatus.isExplainable($0) && vm.explainerID(explaining: $0.id) == nil
                }
                if explainable.isEmpty {
                    Text("Every paper and article here has an explainer.")
                }
                ForEach(explainable) { source in
                    Button(source.title) {
                        Task { await explainers.explain(source, audio: vm) }
                    }
                    .disabled(explainers.isWriting(source.id))
                }
            } label: {
                MobileStudioChip(tile: tile, isBusy: !writingExplainers.isEmpty)
            }
            .accessibilityIdentifier(tile.accessibilityIdentifier)
        case .walkthrough:
            Menu {
                let walkable = ownSources.filter {
                    MobileWalkthroughGenerator.canWalkThrough($0) && walkthroughDeck(for: $0) == nil
                }
                if walkable.isEmpty {
                    Text("Every paper, chapter and article here has a walkthrough.")
                }
                ForEach(walkable) { source in
                    Button(source.title) {
                        walkthroughs.write(source, audio: vm)
                    }
                    .disabled(walkthroughs.isWriting(source.id))
                }
            } label: {
                MobileStudioChip(tile: tile, isBusy: ownSources.contains { walkthroughs.isWriting($0.id) })
            }
            .accessibilityIdentifier(tile.accessibilityIdentifier)
        case .quiz:
            Menu {
                if ownSources.isEmpty {
                    Text("Add sources to be quizzed on them.")
                }
                ForEach(ownSources) { source in
                    Button(source.title) {
                        Task { await vm.startReviewQuiz(sourceID: source.id, utterance: source.title) }
                    }
                }
            } label: {
                MobileStudioChip(tile: tile)
            }
            .disabled(vm.isReviewActive)
            .accessibilityIdentifier(tile.accessibilityIdentifier)
        }
    }

    // MARK: - Cards

    /// Changes when the catalog deals today's cards again or the notebook's
    /// own sources change.
    private var cardsKey: String {
        ([notebook.id, String(vm.memoryCardsRevision)] + notebook.sourceIDs)
            .joined(separator: "|")
    }

    /// The notebook's cards, as the Mac's Studio Cards row counts them and
    /// draws them (`NotebookCardsRow`): Memory's glyph, "Cards", and
    /// "42 kept · 6 due · 9 to check" — every kept card on its sources, the
    /// due ones today's review in the notebook asks, and the drafts on its
    /// sources waiting to be gone through. A tap opens the notebook's cards
    /// to check while any wait (`MobileCardsToCheckScreen`), as the Mac's
    /// row opens To Check, else its Practice (docs/memory-design.md,
    /// "Practice for a notebook"): its kept cards, due, then new, then not
    /// yet due, answers written only for the cards that count. Its menu
    /// offers both.
    private func cardsRow(_ counts: NotebookCardCounts) -> some View {
        let line = MobileCardReviewCopy.studioLine(counts)
        let route: MobileShellRoute = counts.toCheck > 0
            ? .cardsToCheck(notebookID: notebook.id)
            : .notebookPractice(notebookID: notebook.id)
        return NavigationLink(value: route) {
            HStack(spacing: MobileDesign.Spacing.small) {
                MobileStudioOutputRow(systemImage: MemoryReviewSession.sidebarIcon, title: "Cards", line: line)
                // Grey since 2026-10-06 ("Lists are monochrome").
                Text(counts.toCheck > 0 ? "Check" : "Practice")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .contextMenu {
            if counts.toCheck > 0 {
                NavigationLink(value: MobileShellRoute.cardsToCheck(notebookID: notebook.id)) {
                    Label("Cards to Check", systemImage: "checklist")
                }
            }
            if counts.kept > 0 {
                NavigationLink(value: MobileShellRoute.notebookPractice(notebookID: notebook.id)) {
                    Label("Practice", systemImage: MemoryReviewSession.sidebarIcon)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Cards")
        .accessibilityValue(line)
        .accessibilityHint(counts.toCheck > 0 ? "Goes through this notebook's cards to check" : "Practices this notebook's cards")
        .accessibilityIdentifier("notebook.studio.cards")
    }

    // MARK: - Outputs

    /// What the notebook made, dated by when each was made, as the Mac's
    /// `NotebookOutputs.outputs` dates them: a record's creation, an
    /// explainer's arrival, a walk's writing, a course's newest source. Each
    /// carries the sources it was made from, as the Mac counts them: a
    /// record's grounding, the one source a walkthrough or an explainer is
    /// of, a course's sources this phone holds.
    private var outputs: [MobileStudioOutput] {
        var result: [MobileStudioOutput] = []
        let overviews = vm.audioOverviews(inNotebook: notebook.id)
        if !overviews.isEmpty {
            let overviewDates = Dictionary(
                vm.audioOverviewRecords.map { ($0.id, $0.createdAt) },
                uniquingKeysWith: { first, _ in first }
            )
            // The sources each was written from, which its Artifact names.
            let overviewIDs = Set(overviews.map(\.id))
            let sourceIDs = Dictionary(
                vm.notebookArtifacts.filter { overviewIDs.contains($0.id) }.map { ($0.id, $0.sourceIDs) },
                uniquingKeysWith: { first, _ in first }
            )
            for overview in overviews {
                result.append(MobileStudioOutput(
                    id: "overview-\(overview.id)",
                    kind: .audioOverview(overview),
                    title: overview.title,
                    date: overviewDates[overview.id] ?? nil,
                    sourceIDs: sourceIDs[overview.id] ?? []
                ))
            }
        }
        for doc in vm.docs(in: notebook) {
            result.append(MobileStudioOutput(
                id: "doc-\(doc.id)",
                kind: doc.isMnemonicReading ? .mnemonicReading(doc) : .doc(doc),
                title: doc.title,
                date: doc.createdAt,
                sourceIDs: doc.sourceIDs
            ))
        }
        for source in ownSources {
            if let explainerID = vm.explainerID(explaining: source.id) {
                let explainer = vm.sourcesByID[explainerID]
                result.append(MobileStudioOutput(
                    id: "explainer-\(explainerID)",
                    kind: .explainer(source: source, explainerID: explainerID),
                    title: source.title,
                    date: explainer?.dateAdded,
                    sourceIDs: [source.id]
                ))
            }
            if let deck = walkthroughDeck(for: source) {
                result.append(MobileStudioOutput(
                    id: "walkthrough-\(source.id)",
                    kind: .walkthrough(MobileNotebookWalkthrough(source: source, deck: deck)),
                    title: source.title,
                    date: deck.record?.generatedAt,
                    sourceIDs: [source.id]
                ))
            }
        }
        for course in vm.linkedCourses(in: notebook) {
            var seen = Set<String>()
            let held = course.lectureItems
                .map(\.sourceID)
                .filter { vm.sourcesByID[$0] != nil && seen.insert($0).inserted }
            let newestSource = held.compactMap { vm.sourcesByID[$0]?.dateAdded }.max()
            result.append(MobileStudioOutput(
                id: "course-\(course.id)",
                kind: .course(course),
                title: course.title,
                date: newestSource,
                sourceIDs: held
            ))
        }
        return MobileNotebookOutputOrder.ordered(result) {
            MobileNotebookOutputOrder.Key(id: $0.id, title: $0.title, madeAt: $0.date)
        }
    }

    private var writingExplainers: [MobileCloudSource] {
        ownSources.filter { explainers.isWriting($0.id) }
    }

    private var writingWalkthroughs: [MobileCloudSource] {
        ownSources.filter { walkthroughs.isWriting($0.id) && walkthroughDeck(for: $0) == nil }
    }

    /// What the last walkthrough run of a notebook source could not do, as
    /// the Reader says it under its page.
    private var walkthroughNotices: [(source: MobileCloudSource, message: String)] {
        ownSources.compactMap { source in
            guard !walkthroughs.isWriting(source.id), let message = walkthroughs.notices[source.id] else { return nil }
            return (source, message)
        }
    }

    /// The walk this phone has just written, else the one the catalog carries.
    private func walkthroughDeck(for source: MobileCloudSource) -> MobileWalkthroughDeck? {
        walkthroughs.decks[source.id] ?? source.walkthroughDeck
    }

    @ViewBuilder
    private func outputRow(_ output: MobileStudioOutput) -> some View {
        switch output.kind {
        case .audioOverview(let overview):
            MobileStudioAudioOverviewRow(
                overview: overview,
                sourceCount: output.sourceIDs.count,
                madeAt: output.date
            )
        case .doc(let doc):
            NavigationLink(value: MobileShellRoute.doc(doc.id, notebookID: notebook.id)) {
                MobileStudioOutputRow(
                    systemImage: MobileNotebookOutputGlyph.doc,
                    title: doc.title,
                    line: MobileNotebookOutputLine.line(
                        kind: doc.isDraft ? "Draft" : "Page",
                        sourceCount: output.sourceIDs.count,
                        madeAt: output.date
                    )
                )
            }
            .accessibilityIdentifier("notebook.studio.doc")
        case .mnemonicReading(let reading):
            // A reading opens by the Doc's route, which knows it by its kind.
            NavigationLink(value: MobileShellRoute.doc(reading.id, notebookID: notebook.id)) {
                MobileStudioOutputRow(
                    systemImage: MobileNotebookOutputGlyph.mnemonicReading,
                    title: reading.title,
                    line: MobileMnemonicReading.outputLine(
                        sourceCount: output.sourceIDs.count,
                        madeAt: output.date
                    )
                )
            }
            .accessibilityIdentifier("notebook.studio.mnemonicReading")
        case .explainer(let source, let explainerID):
            let isPlaying = vm.currentItem?.id == explainerID && vm.isPlaying
            Button {
                Task { await vm.toggleTextToSpeech(sourceID: explainerID) }
            } label: {
                MobileStudioOutputRow(
                    systemImage: MobileNotebookOutputGlyph.explainer,
                    title: source.title,
                    line: MobileNotebookOutputLine.line(
                        kind: "Explainer",
                        sourceCount: output.sourceIDs.count,
                        madeAt: output.date
                    )
                ) {
                    MobileStudioPlayDisc(
                        isPlaying: isPlaying,
                        isPreparing: vm.isPreparingAudio(sourceID: explainerID)
                    )
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint(isPlaying ? "Pauses it" : "Plays it")
            .accessibilityIdentifier("notebook.studio.explainerRow")
        case .walkthrough(let walk):
            Button {
                walkthroughToPlay = walk
            } label: {
                MobileStudioOutputRow(
                    systemImage: MobileNotebookOutputGlyph.walkthrough,
                    title: walk.source.title,
                    line: MobileNotebookOutputLine.line(
                        kind: "Walkthrough",
                        sourceCount: output.sourceIDs.count,
                        madeAt: output.date
                    )
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("notebook.studio.walkthroughRow")
        case .course(let course):
            NavigationLink {
                MobileCoursePageScreen(courseID: course.id)
            } label: {
                MobileStudioOutputRow(
                    systemImage: MobileNotebookOutputGlyph.course,
                    title: course.title,
                    line: MobileNotebookOutputLine.line(
                        kind: "Course",
                        sourceCount: output.sourceIDs.count,
                        madeAt: output.date
                    )
                )
            }
            .accessibilityIdentifier("notebook.studio.course")
        }
    }

    private func noticeRow(_ source: MobileCloudSource, message: String) -> some View {
        HStack(alignment: .top, spacing: MobileDesign.Spacing.medium) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.body)
                .foregroundStyle(.orange)
                .frame(width: noticeGlyphWidth)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(source.title)
                    .font(.body)
                    .lineLimit(2)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button {
                walkthroughs.notices[source.id] = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(
                        width: MobileDesign.Metrics.minimumTouchTarget,
                        height: MobileDesign.Metrics.minimumTouchTarget
                    )
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .accessibilityIdentifier("notebook.studio.walkthroughNotice")
    }
}

/// A walkthrough the Studio deals: the source it walks and its deck.
struct MobileNotebookWalkthrough: Identifiable {
    let source: MobileCloudSource
    let deck: MobileWalkthroughDeck

    var id: String { source.id }
}

/// One thing made from a notebook, as its Studio lists it.
struct MobileStudioOutput: Identifiable {
    enum Kind {
        case audioOverview(MobileAudioOverviewListing)
        case doc(MobileCloudArtifact)
        case mnemonicReading(MobileCloudArtifact)
        case explainer(source: MobileCloudSource, explainerID: String)
        case walkthrough(MobileNotebookWalkthrough)
        case course(MobileCloudCourse)
    }

    let id: String
    let kind: Kind
    /// What its row is called, which also breaks a tie in the order.
    let title: String
    /// When it was made (never when it was edited); nil when nothing says.
    let date: Date?
    /// The sources it was made from, which its line counts; empty when the
    /// record names none.
    var sourceIDs: [String] = []
}

/// A Studio tile's face, the Mac's chip (`NotebookStudioTileLabel`): its
/// glyph beside its word in a quiet rounded field — neutral fill, hairline
/// stroke — no chevron, even on a tile that picks first, a spinner in the glyph's
/// place while what it makes is being written, dimmed while it cannot be used.
private struct MobileStudioChip: View {
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .subheadline) private var glyphWidth: CGFloat = 22
    let tile: MobileNotebookStudioTile
    var isBusy = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: MobileDesign.Radius.compact, style: .continuous)
        HStack(spacing: MobileDesign.Spacing.small) {
            ZStack {
                Image(systemName: tile.symbolName)
                    .font(.subheadline)
                    .opacity(isBusy ? 0 : 1)
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: glyphWidth)
            .accessibilityHidden(true)
            Text(tile.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.primary)
        .opacity(isEnabled ? 1 : 0.4)
        .padding(.horizontal, MobileDesign.Spacing.medium)
        .frame(maxWidth: .infinity, minHeight: MobileDesign.Metrics.minimumTouchTarget)
        .background(shape.fill(Color.primary.opacity(0.045)))
        .overlay(shape.strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
        .contentShape(shape)
        .accessibilityValue(isBusy ? "Writing" : "")
    }
}

/// One row of the Studio's Outputs, the Mac's (`NotebookOutputRow`): its
/// kind's glyph, quiet, beside its title and its line, a thin bar under them
/// while an overview is partly played, and what it does at the trailing edge.
/// A spinner takes the glyph's place while it is being written.
private struct MobileStudioOutputRow<Trailing: View>: View {
    @ScaledMetric(relativeTo: .body) private var glyphWidth: CGFloat = 24

    let systemImage: String
    let title: String
    let line: String
    var isBusy = false
    /// The fraction listened, for a partly played audio overview.
    var progress: Double? = nil
    let trailing: Trailing

    init(
        systemImage: String,
        title: String,
        line: String,
        isBusy: Bool = false,
        progress: Double? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.systemImage = systemImage
        self.title = title
        self.line = line
        self.isBusy = isBusy
        self.progress = progress
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: MobileDesign.Spacing.small) {
            HStack(alignment: .top, spacing: MobileDesign.Spacing.medium) {
                Group {
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: systemImage)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: glyphWidth)
                .padding(.top, 1)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(line)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let progress {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(Color.accentColor)
                            .padding(.top, 3)
                            .accessibilityHidden(true)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            trailing
        }
        .contentShape(Rectangle())
    }
}

extension MobileStudioOutputRow where Trailing == EmptyView {
    init(systemImage: String, title: String, line: String, isBusy: Bool = false, progress: Double? = nil) {
        self.init(systemImage: systemImage, title: title, line: line, isBusy: isBusy, progress: progress) {
            EmptyView()
        }
    }
}

/// The play disc a playable output ends with (Home's notebook row's): ▶
/// while idle or paused, ❚❚ while it plays, a spinner while its audio is
/// being prepared.
private struct MobileStudioPlayDisc: View {
    let isPlaying: Bool
    let isPreparing: Bool

    var body: some View {
        Group {
            if isPreparing {
                ProgressView()
                    .controlSize(.small)
                    .frame(
                        width: MobileDesign.Metrics.minimumTouchTarget,
                        height: MobileDesign.Metrics.minimumTouchTarget
                    )
            } else {
                MobileCircularActionLabel(systemImage: isPlaying ? "pause.fill" : "play.fill")
            }
        }
        .accessibilityHidden(true)
    }
}

/// One audio overview among the outputs, the Mac's `AudioOverviewOutputRow`
/// on the phone: its glyph, title and "Audio overview · 6 sources · 12 min ·
/// yesterday", a thin bar while it is partly played, then the play disc. A
/// tap on the row plays or pauses it, as the disc does.
///
/// The length is the narration's own, measured once every file of it is on
/// this phone; where it has been listened to is the player's while it plays,
/// else the resume point saved beside it (`MobileAudioOverviewNarrationStore`).
private struct MobileStudioAudioOverviewRow: View {
    let overview: MobileAudioOverviewListing
    let sourceCount: Int
    let madeAt: Date?

    @EnvironmentObject private var vm: MobileAudioReviewViewModel
    @State private var narration: MobileAudioOverviewNarrationStore.Narration?

    private var carrierID: String { overview.carrier.id }
    private var isCurrent: Bool { vm.currentItem?.id == carrierID }
    private var isPlaying: Bool { isCurrent && vm.isPlaying }

    /// Where it has been listened to: the player's position while it holds
    /// the overview, else the saved resume point.
    private var position: TimeInterval? {
        isCurrent ? vm.currentTime : narration?.savedPosition
    }

    private var fraction: Double? {
        MobileAudioOverviewListening.listenedFraction(position: position, duration: narration?.duration)
    }

    private var line: String {
        MobileNotebookOutputLine.line(
            kind: MobileNotebookOutputLine.audioOverviewKind,
            sourceCount: sourceCount,
            length: MobileAudioOverviewListening.lengthLabel(duration: narration?.duration),
            madeAt: madeAt
        )
    }

    /// Read again when the player takes it up, lets it go, pauses it, or
    /// swaps the opening it started on for the whole narration.
    private var narrationKey: String {
        [
            carrierID,
            isCurrent ? "current" : "",
            isPlaying ? "playing" : "",
            String(isCurrent ? vm.currentItem?.manifest.chunks.count ?? 0 : 0),
        ].joined(separator: "|")
    }

    var body: some View {
        let fraction = self.fraction
        HStack(spacing: MobileDesign.Spacing.small) {
            Button(action: toggle) {
                MobileStudioOutputRow(
                    systemImage: MobileNotebookOutputGlyph.audioOverview,
                    title: overview.title,
                    line: line,
                    progress: fraction
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(MobileNotebookOutputLine.audioOverviewKind): \(overview.title)")
            .accessibilityValue(
                [line, fraction.map { "\(Int(($0 * 100).rounded())) percent listened" }]
                    .compactMap { $0 }
                    .joined(separator: ", ")
            )
            .accessibilityHint(isPlaying ? "Pauses it" : "Plays it")
            .accessibilityIdentifier("notebook.studio.audioOverview")

            Button(action: toggle) {
                MobileStudioPlayDisc(isPlaying: isPlaying, isPreparing: vm.isPreparingAudio(sourceID: carrierID))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("notebook.studio.audioOverview.play")
        }
        .task(id: narrationKey) {
            let read = await MobileAudioOverviewNarrationStore.shared.narration(sourceID: carrierID)
            if read != narration { narration = read }
        }
    }

    private func toggle() {
        Task { await vm.toggleTextToSpeech(sourceID: carrierID) }
    }
}

/// What this phone holds of an audio overview's narration, for its Studio
/// row: how long it runs, measured from its audio files once every one of
/// them is on this phone, and the resume point saved beside it
/// (`ArticleSpeechPlaybackPosition`, written by whichever device played it
/// last and carried by iCloud Drive) when it was saved against this
/// narration. Read off the main actor; it never asks iCloud for the audio
/// itself, only for the small manifest and position files, and a length is
/// measured once per narration.
actor MobileAudioOverviewNarrationStore {
    static let shared = MobileAudioOverviewNarrationStore()

    struct Narration: Equatable, Sendable {
        /// Nil until every file of the narration is on this phone.
        var duration: TimeInterval?
        /// Nil when nothing is saved: never played, or played to the end.
        var savedPosition: TimeInterval?
    }

    /// Lengths measured, by carrier, narration and its file count.
    private var durations: [String: TimeInterval] = [:]

    func narration(sourceID: String) async -> Narration {
        await replicaNarration(sourceID: sourceID)
    }

    /// The manifest from the carrier's `audio.*` satellite, fetched by name, and the resume point from this
    /// member's `ReadingState.listen` (§3.5.18, §3.5.30). The length is measured once every chunk (the
    /// manifest's `audioChunk` children) is on this phone: saved offline or played; until then the row
    /// shows none, and nothing is fetched just to measure it.
    private func replicaNarration(sourceID: String) async -> Narration {
        guard let session = await MobileSyncSession.startIfEnabled(),
              let narration = try? await session.satellites.source(sourceID, matching: { $0.hasPrefix("audio.") }),
              let data = try? await session.satellites.data(narration) else { return Narration() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(SyncedArticleAudioManifest.self, from: data) else { return Narration() }
        let state = try? await session.projection.envelope(.readingState, id: "rs:\(sourceID)", zoneKey: MobileProjection.libraryKey)
        let savedPosition = MobileReadModels.listenPosition(state?.fields["listen"], contentSignature: manifest.contentSignature)
        let key = "\(sourceID)#\(manifest.contentSignature)#\(manifest.chunks.count)"
        if let known = durations[key] { return Narration(duration: known, savedPosition: savedPosition) }
        var urls: [URL] = []
        for satellite in MobileNarrationChunks.satellites(of: narration, manifest: manifest) {
            guard let satellite, let url = await session.satellites.localURL(satellite) else {
                return Narration(duration: nil, savedPosition: savedPosition)
            }
            urls.append(url)
        }
        var total: TimeInterval = 0
        for url in urls {
            guard let length = try? await AVURLAsset(url: url).load(.duration).seconds, length.isFinite, length > 0 else {
                return Narration(duration: nil, savedPosition: savedPosition)
            }
            total += length
        }
        guard !urls.isEmpty else { return Narration(duration: nil, savedPosition: savedPosition) }
        durations[key] = total
        return Narration(duration: total, savedPosition: savedPosition)
    }
}

// MARK: - Docs

/// A Doc's body on the phone, fetched from its Artifact record when its
/// revision changed and kept in Caches beside the revision it holds (as
/// `MobileAnimationSiteStore` keeps a site's files). A failed fetch falls
/// back to the copy this phone already holds, if any.
actor MobileNotebookDocStore {
    static let shared = MobileNotebookDocStore()

    enum DocError: LocalizedError {
        case noBody
        /// A linked page (a Google Doc) whose read-only text copy the Mac
        /// has not made yet; the page itself opens from its link.
        case noTextCopy

        var errorDescription: String? {
            switch self {
            case .noBody: return "This Page's text has not reached iCloud yet."
            case .noTextCopy: return "No text copy of this page has reached iCloud yet."
            }
        }
    }

    nonisolated static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotebookDocs", isDirectory: true)
    }

    func markdown(for artifact: MobileCloudArtifact) async throws -> String {
        let file = Self.root.appendingPathComponent("\(artifact.id.lowercased()).md")
        let marker = Self.root.appendingPathComponent("\(artifact.id.lowercased()).revision")
        if let revision = artifact.bodyRevision,
           let held = try? String(contentsOf: marker, encoding: .utf8), held == revision,
           let cached = try? String(contentsOf: file, encoding: .utf8) {
            return cached
        }
        do {
            guard let satellites = await MobileSatellites.current() else {
                throw artifact.linkedURL == nil ? DocError.noBody : DocError.noTextCopy
            }
            let decoded = try await Self.satelliteBody(artifact, satellites: satellites)
            try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
            try Data(decoded.markdown.utf8).write(to: file, options: .atomic)
            try Data(decoded.revision.utf8).write(to: marker, options: .atomic)
            return decoded.markdown
        } catch {
            if let cached = try? String(contentsOf: file, encoding: .utf8) { return cached }
            throw error
        }
    }

    /// The Doc's `body` satellite (docs/cloudkit-schema-design.md §3.5.15, §3.5.30), from wherever the
    /// phone holds the Doc (its `Library` copy, or a space's). Its FileRef's hash is the body's
    /// revision; the body is the Doc's package, or plain Markdown when its writer stored only that.
    static func satelliteBody(_ artifact: MobileCloudArtifact, satellites: MobileSatellites) async throws -> (markdown: String, revision: String) {
        guard let body = try await satellites.locate(.artifact, id: artifact.id, pick: { $0.fields["body"].flatMap(FileRef.init(json:)) }) else {
            throw artifact.linkedURL == nil ? DocError.noBody : DocError.noTextCopy
        }
        let data = try await satellites.data(body)
        if body.file.mime?.lowercased() == "text/markdown" {
            return (String(decoding: data, as: UTF8.self), body.file.hash)
        }
        let package = try ArtifactBodyPackage.decode(data, expectedRevision: body.file.hash)
        return (package.markdown, package.revision)
    }
}

/// A notebook's Doc, read-only on the phone (the Doc editor is the Mac's):
/// its Markdown as headings, paragraphs and lists, pictures named by their
/// alt text, links kept; a link to a source or a notebook opens it here, and
/// the sources it cites are listed under it as rows that open the Reader.
struct MobileNotebookDocView: View {
    let artifact: MobileCloudArtifact
    let notebook: MobileCloudNotebook

    @EnvironmentObject private var vm: MobileAudioReviewViewModel
    @State private var readable: MobileDocMarkdown.Readable?
    @State private var blocks: [MobileDocMarkdown.Block] = []
    @State private var errorMessage: String?
    /// A reading saved back with no kind, known by its body's marker line.
    @State private var isMnemonicReading = false

    var body: some View {
        if isMnemonicReading {
            MobileMnemonicReadingView(artifact: artifact, notebook: notebook, vm: vm)
        } else {
            docBody
        }
    }

    private var docBody: some View {
        List {
            if let url = linkedPageURL {
                Section {
                    Link(destination: url) {
                        Label(artifact.isGoogleDoc ? "Open in Google Docs" : "Open Page", systemImage: "arrow.up.forward.app")
                    }
                }
            }
            Section {
                if let errorMessage, readable == nil {
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if readable == nil {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: MobileDesign.Spacing.medium) {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                            MobileDocBlockView(block: block)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(.vertical, MobileDesign.Spacing.small)
                }
            }
            if !citedSources.isEmpty {
                Section("Sources") {
                    ForEach(citedSources) { source in
                        MobileBrowserSourceLink(source: source, notebook: notebook)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(artifact.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: artifact.bodyRevision ?? artifact.id) {
            await load()
        }
    }

    /// A linked Doc's page (a Google Doc, or a link the Mac files under
    /// Docs), which opens in the browser; the phone shows its text copy.
    private var linkedPageURL: URL? {
        guard let linked = artifact.linkedURL, let url = URL(string: linked),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private var citedSources: [MobileCloudSource] {
        (readable?.citedSourceIDs ?? []).compactMap { vm.sourcesByID[$0] }
    }

    private func load() async {
        do {
            let markdown = try await MobileNotebookDocStore.shared.markdown(for: artifact)
            let kind = artifact.kind
            let made = await Task.detached(priority: .userInitiated) { () -> (MobileDocMarkdown.Readable, [MobileDocMarkdown.Block])? in
                if MobileMnemonicReading.isReading(kind: kind, markdown: markdown) { return nil }
                let readable = MobileDocMarkdown.readable(markdown)
                return (readable, MobileDocMarkdown.blocks(readable.text))
            }.value
            guard let made else {
                isMnemonicReading = true
                return
            }
            readable = made.0
            blocks = made.1
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// One block of a Doc, its inline Markdown (emphasis, code, links) rendered.
private struct MobileDocBlockView: View {
    let block: MobileDocMarkdown.Block

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(level <= 1 ? .title2.weight(.bold) : level == 2 ? .title3.weight(.semibold) : .headline)
                .padding(.top, level <= 2 ? MobileDesign.Spacing.small : 0)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(Self.inline(text))
        case .bullets(let items):
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.xSmall) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: MobileDesign.Spacing.small) {
                        Text("•")
                        Text(Self.inline(item))
                    }
                }
            }
        case .numbered(let items):
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.xSmall) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: MobileDesign.Spacing.small) {
                        Text("\(index + 1).")
                            .monospacedDigit()
                        Text(Self.inline(item))
                    }
                }
            }
        case .quote(let text):
            Text(Self.inline(text))
                .foregroundStyle(.secondary)
                .padding(.leading, MobileDesign.Spacing.medium)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.4))
                        .frame(width: 3)
                }
        case .code(let text):
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .padding(MobileDesign.Spacing.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        case .rule:
            Divider()
        }
    }

    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
