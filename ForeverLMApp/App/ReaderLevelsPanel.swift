#if os(macOS)
import SwiftUI
import os

// MARK: - Levels in the Reader
//
// docs/sensemaking-design.md, "Levels in the Reader". A trailing panel beside
// the real PDF or article — never a re-typeset copy of it (product owner,
// 2026-10-04: overlay on the paper, no new reading surface) — that shows the
// source zoomed out: its gist, a line per section and per paragraph, and its
// key terms. With Follow on, the section under the learner's place opens to
// its paragraphs' lines and the others stay one line each (focus and
// context: Wattenberger's fisheye on text), and scrolling the source moves
// the opening along. A click on a line scrolls the Reader there and flashes
// the passage, through the same request a chat citation makes
// (`requestReaderPassage`), so every reader that flashes a citation —
// PDF, web article, EPUB, plain text — takes it. Opening the panel reads
// the stored levels and writes nothing; Write Levels is the learner's press.

/// What the panel knows about the source on screen, read off the main actor
/// and published here.
@MainActor
@Observable
final class ReaderLevelsModel {
    private static let logger = Logger(subsystem: "com.foreverlm", category: "ReaderLevels")
    enum Phase: Equatable {
        case loading
        /// No levels written for this source yet.
        case none
        case ready
        case unreadable(String)
    }

    private(set) var sourceID: String?
    private(set) var phase: Phase = .loading
    private(set) var levels: SourceLevels?
    /// The source's text changed since its levels were written.
    private(set) var isStale = false
    /// Each paragraph's words in the current text, for a term's passage.
    private(set) var paragraphTexts: [Int: String] = [:]
    /// The page each paragraph starts on, from 0, for a source read as a PDF.
    private(set) var pages: [Int: Int] = [:]
    /// Where each paragraph starts, as a share of the text.
    private(set) var positions: [Int: Double] = [:]
    /// The paragraph the learner clicked last, marked until their place moves.
    var clickedParagraph: Int?
    /// Sections the learner opened or closed by hand, over what Follow does.
    var openedSections: Set<Int> = []
    var closedSections: Set<Int> = []
    /// The learner's latest Think first take on the source, drawn above the
    /// gist: their line before ForeverLM's (docs/fences-and-think-first-design.md).
    private(set) var latestTake: ThinkFirstTake?
    /// The levels wait for the learner's own line first: Think first asks
    /// here, this source has no take yet, and this Mac has not asked before.
    private(set) var asksFirst = false

    @ObservationIgnored private var loadToken = 0
    /// Page maps found this session, by source and text: an anchor is
    /// searched for once.
    private static var pageMaps: [String: [Int: Int]] = [:]

    nonisolated init() {}

    /// `thinksFirst` is whether Think first asks before a source's gist where
    /// the panel is (the window's notebook, else the library).
    func load(article: StudioArticle, storage: StorageService, thinksFirst: Bool = false) async {
        loadToken += 1
        let token = loadToken
        let sourceID = article.id
        if self.sourceID != sourceID {
            self.sourceID = sourceID
            phase = .loading
            levels = nil
            isStale = false
            latestTake = nil
            asksFirst = false
            paragraphTexts = [:]
            pages = [:]
            positions = [:]
            clickedParagraph = nil
            openedSections = []
            closedSections = []
        }
        let state: (levels: SourceLevels?, currentSHA256: String?, text: String?)
        do {
            state = try await storage.sourceLevelsState(sourceID: sourceID)
        } catch {
            guard token == loadToken else { return }
            phase = .unreadable(error.localizedDescription)
            return
        }
        guard token == loadToken else { return }
        guard let levels = state.levels else {
            // Write Levels says itself when the source has no text: a source
            // whose text is read from its file holds none stored until then.
            self.levels = nil
            phase = .none
            return
        }
        let stale = state.currentSHA256.map { levels.isStale(currentSHA256: $0) } ?? false
        // A take written on another Mac is in the understanding document,
        // which is read before the levels show, so they are never shown first
        // and then taken away. Unreadable reads as none: the ask then comes,
        // and answering it writes the document again.
        let takes: [ThinkFirstTake]
        do {
            takes = try await storage.thinkFirstTakes(sourceID: sourceID)
        } catch {
            Self.logger.error("Reading the earlier takes failed: \(error.localizedDescription, privacy: .public)")
            takes = []
        }
        guard token == loadToken else { return }
        latestTake = takes.last
        asksFirst = thinksFirst && takes.isEmpty && !ThinkFirstAskedSources.contains(sourceID)
        self.levels = levels
        isStale = stale
        phase = .ready

        // The text as the levels numbered it, cut off the main actor. Stale
        // levels were numbered over another text: their paragraphs keep only
        // their order and their anchors.
        let text = stale ? nil : state.text
        let numbered = await Task.detached(priority: .userInitiated) { () -> [SourceLevelsText.Block] in
            guard let text else { return [] }
            return SourceLevelsText.paragraphs(SourceLevelsText.blocks(of: text))
        }.value
        guard token == loadToken else { return }
        let ordered = levels.sections.flatMap(\.paragraphs)
        if numbered.isEmpty {
            let count = Double(max(1, ordered.count))
            positions = Dictionary(ordered.enumerated().map { ($1.index, Double($0) / count) }, uniquingKeysWith: { first, _ in first })
        } else {
            paragraphTexts = Dictionary(numbered.compactMap { block in block.number.map { ($0, block.text) } }, uniquingKeysWith: { first, _ in first })
            positions = Dictionary(numbered.compactMap { block in block.number.map { ($0, block.position) } }, uniquingKeysWith: { first, _ in first })
            let paged = numbered.compactMap { block in block.number.flatMap { number in block.page.map { (number, $0) } } }
            if !paged.isEmpty {
                pages = Dictionary(paged, uniquingKeysWith: { first, _ in first })
                return
            }
        }
        await locatePages(article: article, levels: levels, token: token)
    }

    /// The page each paragraph starts on in the source's PDF, searched once
    /// a session off the main actor, for a source whose stored text keeps no
    /// page boundaries (a paper's cleaned text).
    private func locatePages(article: StudioArticle, levels: SourceLevels, token: Int) async {
        let key = "\(levels.sourceID)#\(levels.contentSHA256)"
        if let known = Self.pageMaps[key] {
            pages = known
            return
        }
        guard article.isPDF, let path = article.cachedResolvedPDFPath else { return }
        let url = URL(fileURLWithPath: path)
        // An evicted iCloud copy is left alone: the Reader downloads it, and
        // the next open finds the pages.
        guard await AsyncPDFDocumentLoader.isLocallyAvailable(url: url),
              let document = await AsyncPDFDocumentLoader.load(url: url) else { return }
        let anchors = levels.sections.flatMap(\.paragraphs).map { (number: $0.index, anchor: $0.anchor) }
        // A book chapter is its pages of the book's file, numbered from its first.
        let range = article.bookPages ?? 0..<document.pageCount
        let found = await Task.detached(priority: .utility) { () -> [Int: Int] in
            guard range.upperBound <= document.pageCount else { return [:] }
            let texts = range.map { document.page(at: $0)?.string ?? "" }
            return SourceLevelsPageLocator.pages(for: anchors, pageTexts: texts)
        }.value
        guard token == loadToken, !found.isEmpty else { return }
        Self.pageMaps[key] = found
        pages = found
    }

    /// The learner's line, kept in the source's understanding document, then
    /// the levels beside it. Throws when it could not be kept; the ask stays.
    func answerFirst(take: String, question: String, article: StudioArticle, storage: StorageService) async throws {
        let sourceID = article.id
        let document = try await storage.appendThinkFirstTake(
            sourceID: sourceID,
            title: article.title,
            question: question,
            take: take
        )
        ThinkFirstAskedSources.insert(sourceID)
        ThinkFirstTally.record(.sourceSummary, answered: true)
        guard self.sourceID == sourceID else { return }
        latestTake = document.thinkFirstTakes.last
        asksFirst = false
    }

    /// Skip: ForeverLM's levels at once, and this Mac does not ask about the
    /// source again.
    func skipFirst() {
        guard let sourceID else { return }
        ThinkFirstAskedSources.insert(sourceID)
        ThinkFirstTally.record(.sourceSummary, answered: false)
        asksFirst = false
    }

    /// The page to open when a passage is not found: one-based, within the
    /// source's own pages, as a citation names it.
    func citationPage(ofParagraph index: Int) -> Int? {
        pages[index].map { $0 + 1 }
    }
}

// MARK: - The panel

struct ReaderLevelsPanel: View {
    let article: StudioArticle

    @Environment(StudioViewModel.self) private var vm
    /// The Studio window it is in; nil in a pop-out Source Reader window.
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?
    @Environment(\.uiZoomScale) private var uiZoomScale
    @ObservedObject private var coordinator = SourceLevelsCoordinator.shared
    @State private var model = ReaderLevelsModel()
    @State private var rememberingAll = false
    @State private var remembering: Set<String> = []
    /// The learner's line while Think first asks before the levels.
    @State private var takeDraft = ""
    @State private var takeError: String?
    @State private var isKeepingTake = false

    private var state: ReaderLevelsPanelState { ReaderLevelsPanelState.shared }
    private var sourceID: String { article.id }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 320 * uiZoomScale)
        .frame(maxHeight: .infinity)
        .background(.background.secondary)
        .task(id: article.id) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .sourceLevelsDidChange)) { note in
            guard note.object as? String == article.id else { return }
            Task { await load() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Levels")
    }

    private func load() async {
        seedPositionIfNeeded()
        let thinksFirst = ThinkFirst.asks(.sourceSummary, notebookID: windowState?.notebook?.notebookID)
        await model.load(article: article, storage: vm.storage, thinksFirst: thinksFirst)
    }

    /// The place the Reader opened at, before the learner has scrolled: a
    /// reader reports only the pages it moves to.
    private func seedPositionIfNeeded() {
        let feed = ReaderLevelsPositionFeed.shared
        guard feed.position(for: sourceID) == nil else { return }
        if let page = vm.readingPositionPage(for: sourceID) ?? article.readingPositionPage {
            feed.note(.page(page), for: sourceID)
        } else if let fraction = SourceProgressDepth.fraction(locator: vm.readingPositionLocator(for: sourceID) ?? article.readingPositionLocator) {
            feed.note(.fraction(fraction), for: sourceID)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Levels")
                    .font(.subheadline.weight(.semibold))
                    .textSelection(.disabled)
                Spacer()
                if model.phase == .ready, !coordinator.isWriting(sourceID) {
                    Button(action: write) {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.hoverWash)
                    .help("Write this source's levels again")
                    .accessibilityLabel("Rewrite levels")
                    .accessibilityIdentifier("reader.levels.rewrite")
                }
                Button {
                    state.isVisible = false
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hoverWash)
                .help("Hide Levels")
                .accessibilityLabel("Hide Levels")
                .accessibilityIdentifier("reader.levels.close")
            }
            if model.phase == .ready, !model.asksFirst {
                Picker("Zoom", selection: Binding(get: { state.zoom }, set: { state.zoom = $0 })) {
                    ForEach(ReaderLevelsPanelState.Zoom.allCases) { zoom in
                        Text(zoom.title).tag(zoom)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("How far to zoom out: the source's point, a line a section, or a line a paragraph")
                .accessibilityIdentifier("reader.levels.zoom")
                if state.zoom != .gist {
                    Toggle("Follow where I am", isOn: Binding(get: { state.follows }, set: { state.follows = $0 }))
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .help(state.zoom == .sections
                            ? "Open the section you are reading to its paragraphs as you scroll; the others stay one line"
                            : "Keep the paragraph you are reading in view as you scroll")
                        .accessibilityIdentifier("reader.levels.follow")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let run = coordinator.run(for: sourceID)
        switch model.phase {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .none:
            if let run {
                centered { progressLine(run) }
            } else {
                emptyState
            }
        case .unreadable(let message):
            centered {
                VStack(spacing: 10) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.disabled)
                    if let run {
                        progressLine(run)
                    } else {
                        actionButton("Rewrite Levels", systemImage: "arrow.clockwise", action: write)
                    }
                }
            }
        case .ready:
            if let levels = model.levels {
                VStack(spacing: 0) {
                    if let run {
                        progressLine(run)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        Divider()
                    } else if model.isStale {
                        staleBanner
                        Divider()
                    } else if let failure = coordinator.failure(for: sourceID) {
                        failureLine(failure)
                        Divider()
                    }
                    if model.asksFirst {
                        thinkFirstAsk
                    } else {
                        levelsList(levels)
                    }
                }
            }
        }
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack {
            Spacer()
            content()
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        centered {
            VStack(spacing: 10) {
                Image(systemName: "list.bullet.indent")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text("Zoom out on this source")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .textSelection(.disabled)
                actionButton("Write Levels", systemImage: "sparkles", action: write)
                    .accessibilityIdentifier("reader.levels.write")
                if let failure = coordinator.failure(for: sourceID) {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.disabled)
                }
            }
        }
    }

    private func actionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                .contentShape(Capsule())
        }
        .buttonStyle(.hoverWash(in: Capsule(), inset: 0, opacity: 0.10, tint: .accentColor))
    }

    private func progressLine(_ run: SourceLevelsCoordinator.Run) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(run.progress.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.disabled)
                .accessibilityIdentifier("reader.levels.progress")
            Spacer(minLength: 0)
            Button("Stop") { coordinator.cancel(sourceID) }
                .buttonStyle(.hoverWash(cornerRadius: 5, inset: -4))
                .font(.caption.weight(.medium))
                .help("Stop writing; nothing is saved")
                .accessibilityIdentifier("reader.levels.stop")
        }
    }

    private var staleBanner: some View {
        HStack(spacing: 8) {
            Text("Written for an earlier version of this text.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.disabled)
            Spacer(minLength: 0)
            Button("Rewrite", action: write)
                .buttonStyle(.hoverWash(cornerRadius: 5, inset: -4))
                .font(.caption.weight(.medium))
                .help("Write the levels again from the text as it is now")
                .accessibilityIdentifier("reader.levels.rewriteStale")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    private func failureLine(_ failure: String) -> some View {
        Text(failure)
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .textSelection(.disabled)
    }

    // MARK: Think first

    /// What the panel asks before it shows ForeverLM's levels of a source the
    /// first time (docs/fences-and-think-first-design.md, "Think first"):
    /// the learner's expectation of a source not read yet, their gist of one
    /// they have read. Return keeps their line in the source's understanding
    /// document and shows the levels with it above the gist; Skip shows the
    /// levels at once. Either way this Mac does not ask about the source again.
    private var thinkFirstQuestion: String {
        article.isRead ? "What's the gist, in a line?" : "What do you expect this to say?"
    }

    private var thinkFirstAsk: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(thinkFirstQuestion)
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.disabled)
            TextField("In your words", text: $takeDraft, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.roundedBorder)
                .onSubmit(answerFirst)
                .disabled(isKeepingTake)
                .accessibilityIdentifier("reader.levels.thinkFirst.field")
            if let takeError {
                Text(takeError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.disabled)
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Skip", action: model.skipFirst)
                    .buttonStyle(.hoverWash(cornerRadius: 5, inset: -4))
                    .font(.callout)
                    .disabled(isKeepingTake)
                    .help("Show the levels now")
                    .accessibilityIdentifier("reader.levels.thinkFirst.skip")
                actionButton("Show Levels", systemImage: "arrow.right", action: answerFirst)
                    .disabled(ThinkFirst.take(takeDraft) == nil || isKeepingTake)
                    .help("Keep your line with this source, then show the levels beside it")
                    .accessibilityIdentifier("reader.levels.thinkFirst.answer")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func answerFirst() {
        guard let take = ThinkFirst.take(takeDraft), !isKeepingTake else { return }
        let question = thinkFirstQuestion
        isKeepingTake = true
        takeError = nil
        Task {
            defer { isKeepingTake = false }
            do {
                try await model.answerFirst(take: take, question: question, article: article, storage: vm.storage)
                takeDraft = ""
            } catch {
                takeError = "Your line was not kept. \(error.localizedDescription)"
            }
        }
    }

    /// The learner's own line above ForeverLM's gist, as they wrote it.
    private func takeView(_ take: ThinkFirstTake) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your take")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textSelection(.disabled)
            Text(take.text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("reader.levels.thinkFirst.take")
    }

    // MARK: The levels

    private func focus(in levels: SourceLevels) -> SourceLevelsFocus {
        let position = ReaderLevelsPositionFeed.shared.position(for: sourceID)
        var focus = SourceLevelsFocus.of(position, levels: levels, pages: model.pages, positions: model.positions)
        if focus.paragraphs.isEmpty, let clicked = model.clickedParagraph {
            focus.paragraphs = [clicked]
            focus.sections = Set([levels.sectionIndex(ofParagraph: clicked)].compactMap { $0 })
        }
        return focus
    }

    /// What Follow keeps in view: the open section, or in the Paragraphs zoom
    /// the paragraph itself.
    private func followTarget(_ focus: SourceLevelsFocus) -> String? {
        switch state.zoom {
        case .gist: return nil
        case .sections: return focus.primarySection.map { "section-\($0)" }
        case .paragraphs: return focus.paragraphs.min().map { "paragraph-\($0)" }
        }
    }

    private func levelsList(_ levels: SourceLevels) -> some View {
        let focus = focus(in: levels)
        let target = followTarget(focus)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    switch state.zoom {
                    case .gist:
                        gistView(levels)
                    case .sections, .paragraphs:
                        ForEach(Array(levels.sections.enumerated()), id: \.offset) { index, section in
                            sectionView(section, index: index, levels: levels, focus: focus)
                                .id("section-\(index)")
                        }
                    }
                    termsView(levels)
                        .padding(.top, 10)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
            .onChange(of: target) { _, target in
                guard state.follows, let target else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(target, anchor: .center)
                }
            }
            .onAppear {
                guard state.follows, let target else { return }
                proxy.scrollTo(target, anchor: .center)
            }
        }
    }

    // MARK: Gist

    private func gistView(_ levels: SourceLevels) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let take = model.latestTake {
                takeView(take)
            }
            voice(levels.gist, mark: true, size: 14)
            if !levels.why.isEmpty {
                voice(levels.why, mark: true, size: 12)
            }
            if !levels.findings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Key findings")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textSelection(.disabled)
                    ForEach(Array(levels.findings.enumerated()), id: \.offset) { _, finding in
                        findingRow(finding, levels: levels)
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }

    private func findingRow(_ finding: SourceLevels.Finding, levels: SourceLevels) -> some View {
        let section = finding.sectionIndex.flatMap { levels.sections.indices.contains($0) ? levels.sections[$0] : nil }
        return Button {
            if let section, let first = section.paragraphs.first { jump(to: first) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                voice(finding.text, mark: false, size: 12)
                if let section {
                    Text(section.title)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: 0.07))
        .disabled(section == nil)
        .help(section.map { "Go to \u{201C}\($0.title)\u{201D}" } ?? "")
    }

    // MARK: Sections and paragraphs

    private func isExpanded(_ index: Int, focus: SourceLevelsFocus) -> Bool {
        if state.zoom == .paragraphs { return true }
        if model.closedSections.contains(index) { return false }
        if model.openedSections.contains(index) { return true }
        return state.follows && focus.sections.contains(index)
    }

    private func sectionView(_ section: SourceLevels.Section, index: Int, levels: SourceLevels, focus: SourceLevelsFocus) -> some View {
        let expanded = isExpanded(index, focus: focus)
        let current = focus.sections.contains(index)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 2) {
                Button {
                    if let first = section.paragraphs.first { jump(to: first) }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(section.title)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if !section.line.isEmpty {
                            voice(section.line, mark: true, size: 12)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: 0.07))
                .help("Go to this section in the source")
                .accessibilityIdentifier("reader.levels.section.\(index)")

                if state.zoom == .sections, !section.paragraphs.isEmpty {
                    Button {
                        toggle(index, expanded: expanded)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.hoverWash(cornerRadius: 5, inset: -2))
                    .padding(.top, 6)
                    .help(expanded ? "Hide this section's paragraphs" : "Show this section's paragraphs")
                    .accessibilityLabel(expanded ? "Hide paragraphs" : "Show paragraphs")
                }
            }
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(section.paragraphs, id: \.index) { paragraph in
                        paragraphRow(paragraph, marked: focus.paragraphs.contains(paragraph.index))
                            .id("paragraph-\(paragraph.index)")
                    }
                }
                .padding(.leading, 10)
                .padding(.bottom, 4)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(current && state.zoom == .sections ? 0.07 : 0))
        }
        .padding(.bottom, 2)
        .animation(.easeInOut(duration: 0.18), value: expanded)
    }

    private func toggle(_ index: Int, expanded: Bool) {
        if expanded {
            model.openedSections.remove(index)
            model.closedSections.insert(index)
        } else {
            model.closedSections.remove(index)
            model.openedSections.insert(index)
        }
    }

    private func paragraphRow(_ paragraph: SourceLevels.Paragraph, marked: Bool) -> some View {
        Button {
            jump(to: paragraph)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("¶\(paragraph.index)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(marked ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .frame(minWidth: 24, alignment: .trailing)
                if paragraph.line.isEmpty {
                    // No line was written for it: its own opening words, in
                    // the source's voice.
                    Text("\u{201C}\(paragraph.anchor)\u{2026}\u{201D}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    voice(paragraph.line, mark: false, size: 11.5)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .overlay(alignment: .leading) {
                if marked {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.accentColor)
                        .frame(width: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 5, inset: 0, opacity: 0.07))
        .help("Go to this paragraph in the source")
        .accessibilityLabel(paragraph.line.isEmpty ? "Paragraph \(paragraph.index)" : "Paragraph \(paragraph.index): \(paragraph.line)")
        .accessibilityValue(marked ? "Where you are" : "")
    }

    // MARK: Key terms

    private func termsView(_ levels: SourceLevels) -> some View {
        let expanded = Binding(
            get: { !state.foldedTerms.contains(sourceID) },
            set: { open in
                if open { state.foldedTerms.remove(sourceID) } else { state.foldedTerms.insert(sourceID) }
            }
        )
        return Group {
            if !levels.terms.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Divider()
                    HStack(spacing: 6) {
                        Button {
                            expanded.wrappedValue.toggle()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                                Text("Key terms")
                                    .font(.caption.weight(.semibold))
                                Text("\(levels.terms.count)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.hoverWash(cornerRadius: 5, inset: -3))
                        .help(expanded.wrappedValue ? "Hide the key terms" : "Show the key terms")
                        .accessibilityIdentifier("reader.levels.terms")
                        Spacer(minLength: 0)
                        if expanded.wrappedValue {
                            Button(rememberingAll ? "Drafting…" : "Remember All") {
                                remember(levels.terms, all: true)
                            }
                            .buttonStyle(.hoverWash(cornerRadius: 5, inset: -4))
                            .font(.caption.weight(.medium))
                            .disabled(rememberingAll)
                            .help("Draft a card for each term into To Check")
                            .accessibilityIdentifier("reader.levels.rememberAll")
                        }
                    }
                    .padding(.top, 4)
                    if expanded.wrappedValue {
                        ForEach(levels.terms, id: \.term) { term in
                            termRow(term)
                        }
                    }
                }
            }
        }
    }

    private func termRow(_ term: SourceLevels.Term) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Button {
                    jump(toTerm: term)
                } label: {
                    Text(term.term)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hoverWash(cornerRadius: 5, inset: -3))
                .disabled(term.anchor == nil)
                .help(term.anchor == nil ? "" : "Go to where the source uses this term")
                Spacer(minLength: 0)
                let busy = remembering.contains(term.term) || rememberingAll
                Button(busy ? "Drafting…" : "Remember") {
                    remember([term], all: false)
                }
                .buttonStyle(.hoverWash(cornerRadius: 5, inset: -4))
                .font(.caption.weight(.medium))
                .disabled(busy)
                .help("Draft a card for this term into To Check")
            }
            voice(term.definition, mark: false, size: 12)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
    }

    // MARK: Actions

    private func write() {
        let storage = vm.storage
        let id = sourceID
        Task { @MainActor in
            let result = await coordinator.write(sourceID: id, storage: storage)
            switch result {
            case .success:
                break
            case .failure(let error):
                if error is CancellationError {
                    vm.showToast("Stopped writing the levels")
                } else {
                    vm.showToast(error.localizedDescription)
                }
            }
        }
    }

    /// Scrolls the Reader to a paragraph and flashes its opening words, as
    /// a chat citation does; a PDF opens the paragraph's page when the words
    /// are not found on it.
    private func jump(to paragraph: SourceLevels.Paragraph) {
        model.clickedParagraph = paragraph.index
        guard !paragraph.anchor.isEmpty else { return }
        vm.requestReaderPassage(paragraph.anchor, page: model.citationPage(ofParagraph: paragraph.index), for: sourceID)
    }

    private func jump(toTerm term: SourceLevels.Term) {
        guard let anchor = term.anchor else { return }
        if let index = term.paragraphIndex { model.clickedParagraph = index }
        vm.requestReaderPassage(anchor, page: term.paragraphIndex.flatMap { model.citationPage(ofParagraph: $0) }, for: sourceID)
    }

    /// Drafts a card for each term into To Check, anchored to the passage
    /// the source defines or first uses it in (`SituatedCardDrafter`).
    private func remember(_ terms: [SourceLevels.Term], all: Bool) {
        guard !terms.isEmpty else { return }
        let anchors = terms.map { term -> SituatedAnchor in
            let passage = term.paragraphIndex.flatMap { model.paragraphTexts[$0] } ?? term.anchor
            return SituatedAnchor(
                kind: .term,
                text: "\(term.term): \(term.definition)",
                sourceIDs: [sourceID],
                passages: passage.map { [SituatedPassage(sourceID: sourceID, text: $0)] } ?? []
            )
        }
        let names = Set(terms.map(\.term))
        if all { rememberingAll = true } else { remembering.formUnion(names) }
        let id = sourceID
        let window = windowState
        Task { @MainActor in
            defer {
                if all { rememberingAll = false } else { remembering.subtract(names) }
            }
            do {
                let outcome = try await SituatedCardDrafter.draft(anchors, studio: vm)
                vm.showToast(
                    Self.rememberedMessage(outcome),
                    action: outcome.drafted > 0
                        ? StudioToastAction(title: "Check") { target in
                            guard let place = target ?? window else { return }
                            vm.openCardsToCheckBesideReader(sourceID: id, in: place)
                        }
                        : nil
                )
            } catch {
                vm.showToast(error.localizedDescription)
            }
        }
    }

    /// "3 cards drafted to To Check", "1 card drafted · 1 not grounded".
    static func rememberedMessage(_ outcome: SituatedCardDrafter.Outcome) -> String {
        var parts: [String]
        switch outcome.drafted {
        case 0: parts = ["No cards drafted"]
        case 1: parts = ["1 card drafted to To Check"]
        default: parts = ["\(outcome.drafted) cards drafted to To Check"]
        }
        if outcome.notGrounded > 0 {
            parts.append(outcome.notGrounded == 1 ? "1 not grounded in the text" : "\(outcome.notGrounded) not grounded in the text")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Voice

    /// ForeverLM's own words: italic, secondary, and led by ✦ where `mark`.
    private func voice(_ text: String, mark: Bool, size: CGFloat) -> some View {
        Text(mark ? "\u{2726} " + text : text)
            .zoomedSystemFont(size: size)
            .italic()
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.disabled)
    }
}

// MARK: - The ⋯ menu's item

/// Show Levels / Hide Levels, in the Reader's ⋯ menu: shows or hides the
/// Levels panel. The Reader's ⋯ is its only way to the panel (Quiet
/// chrome, docs/ui-design.md): the bar has no Levels button.
struct ReaderLevelsMenuItem: View {
    let article: StudioArticle

    private var state: ReaderLevelsPanelState { ReaderLevelsPanelState.shared }

    var body: some View {
        if ReaderLevels.offers(article) {
            Button {
                state.isVisible.toggle()
            } label: {
                Label(state.isVisible ? "Hide Levels" : "Show Levels", systemImage: "list.bullet.indent")
            }
            .help("See this source zoomed out: its gist, a line per section and per paragraph, and its key terms")
        }
    }
}
#endif
