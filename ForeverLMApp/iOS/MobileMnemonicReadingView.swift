import OSLog
import SwiftUI
import UIKit

// A mnemonic reading on the iPhone and iPad (docs/memory-design.md, "Mnemonic
// reading (2026-10-03)"): the Mac's reading view in the phone's idiom. Each
// source in reading order under its title, its own stored text set block by
// block in the Reader's serif face, and after the paragraph that holds a
// question's quote, the question. **Show Answer** turns it over; **Forgot** or
// **Remembered** keeps it as a Memory card (`MobileMnemonicReadingAnswer`,
// written through `MobileMemoryAttemptRecorder`) and folds it to one quiet
// line, which opens again on a tap. A source's text is read off the main actor
// as its place comes into view, never the whole book at once. What the
// learner answered is read from Memory; nothing is written into the reading.

// MARK: - The model

@MainActor
final class MobileMnemonicReadingModel: ObservableObject {
    /// Everything the reading reads and writes, so a test names its own.
    struct Backend {
        /// The reading's body (its Artifact record's Markdown).
        var body: @MainActor () async throws -> String
        /// A source's stored text, as synced.
        var text: @MainActor (_ sourceID: String) async throws -> String
        /// A source's title in this phone's library; nil when the phone does
        /// not hold it.
        var title: @MainActor (_ sourceID: String) -> String?
        /// A source's identity, written beside a kept card's item so a device
        /// whose copy has another id finds it.
        var identity: @MainActor (_ sourceID: String) -> MobileReviewSourceIdentityPayload?
        /// The items the questions kept (by item id) and their attempts, as
        /// the phone holds them.
        var held: @MainActor (_ itemIDs: Set<String>) async -> (items: [MemoryItem], attempts: [MemoryAttempt])
        /// A first answer: the card's item and first attempt, saved together.
        var keep: @MainActor (_ item: MemoryItem, _ identities: [MobileReviewSourceIdentityPayload], _ attempt: MemoryAttempt) async throws -> MobileMemoryAttemptRecorder.KeepResult
        /// A later answer to a kept card.
        var write: @MainActor (_ attempt: MemoryAttempt, _ parentCurriculumFingerprint: String) async throws -> MemoryCardAnswerOutcome
        /// A kept card and its first attempt, published in the catalog.
        var noteKept: @MainActor (_ item: MemoryItem, _ attempt: MemoryAttempt) async -> Void
        /// A later answer, published in the catalog.
        var noteRecorded: @MainActor (_ attempt: MemoryAttempt) async -> Void
        /// Holds the app awake while a write runs; the closure it returns
        /// lets go.
        var keepAwake: @MainActor () -> () -> Void
        var now: @MainActor () -> Date = { Date() }
    }

    let readingID: String
    let fallbackTitle: String
    /// This opening of the reading: one answer per card per sitting, as the
    /// card review counts them.
    let sittingKey: String

    @Published private(set) var reading: MnemonicReading?
    @Published private(set) var loadError: String?
    @Published private(set) var texts: [String: MnemonicReadingSourceText] = [:]
    @Published private(set) var titles: [String: String] = [:]
    /// Where each answered question stands in Memory, by question id.
    @Published private(set) var memory: [String: MnemonicQuestionMemory] = [:]
    @Published private(set) var rows: [MnemonicReadingRow] = []
    /// Questions whose answer is shown.
    @Published var revealed: Set<String> = []
    /// Answered questions opened again from their quiet line.
    @Published var unfolded: Set<String> = []
    /// Answers being written.
    @Published private(set) var answering: Set<String> = []
    /// Why an answer could not be written, by question id.
    @Published private(set) var answerErrors: [String: String] = [:]
    /// The question last answered or opened, which Next goes on from.
    var currentQuestionID: String?

    private let backend: Backend
    /// Each source's stored text as synced: placed again when the reading
    /// grows, and what a first answer's anchor is hashed from.
    private var storedTexts: [String: String] = [:]
    private var textsInFlight = Set<String>()
    /// The questions' items and attempts on this phone.
    private var heldItems: [String: MemoryItem] = [:]
    private var heldAttempts: [MemoryAttempt] = []
    private static let logger = Logger(subsystem: "com.foreverlm.mobile", category: "MnemonicReading")

    init(
        readingID: String,
        fallbackTitle: String,
        sittingToken: String = String(UUID().uuidString.prefix(8)).lowercased(),
        backend: Backend
    ) {
        self.readingID = readingID
        self.fallbackTitle = fallbackTitle
        self.sittingKey = MobileMnemonicReading.sittingKey(readingID: readingID, token: sittingToken)
        self.backend = backend
    }

    // MARK: Counts

    func counts() -> MnemonicReadingProgress.Counts {
        guard let reading else { return .init(questions: 0, answered: 0, due: 0) }
        return MnemonicReadingProgress.counts(of: reading, memory: memory, now: backend.now())
    }

    /// The next question not answered yet after the current one, going round
    /// to the start; nil when every one is answered.
    func nextUnansweredQuestionID() -> String? {
        guard let reading else { return nil }
        let order = MnemonicReadingRows.questionOrder(of: reading, texts: texts)
        return MnemonicReadingProgress.nextUnanswered(in: order, answered: Set(memory.keys), after: currentQuestionID)
    }

    func sourceID(ofQuestion questionID: String) -> String? {
        reading?.question(id: questionID)?.sourceID
    }

    func canAnswer(_ questionID: String) -> Bool {
        MobileMnemonicReadingMemory.canAnswer(questionID, sourceID: sourceID(ofQuestion: questionID), memory: memory, texts: texts)
    }

    func isDue(_ memory: MnemonicQuestionMemory) -> Bool {
        memory.isDue(at: backend.now())
    }

    // MARK: Reading

    /// Reads the body and where its questions stand in Memory. Sources read
    /// already are placed again when their questions changed; the others
    /// wait to come into view.
    func load() async {
        do {
            let markdown = try await backend.body()
            let read = await Task.detached(priority: .userInitiated) { [fallbackTitle] in
                MnemonicReading.parse(markdown, fallbackTitle: fallbackTitle)
            }.value
            let changed = read.sections.filter { section in
                reading?.section(sourceID: section.sourceID)?.questions != section.questions
            }.map(\.sourceID)
            reading = read
            loadError = nil
            var titles: [String: String] = [:]
            for section in read.sections {
                if let title = backend.title(section.sourceID) { titles[section.sourceID] = title }
            }
            self.titles = titles
            for sourceID in changed {
                if let text = storedTexts[sourceID], let section = read.section(sourceID: sourceID) {
                    texts[sourceID] = .loaded(await Self.layout(text: text, questions: section.questions))
                }
            }
            rebuildRows()
            await refreshMemory()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Reads one source's text off the main actor and places its questions
    /// in it, once.
    func loadText(of sourceID: String) async {
        guard let section = reading?.section(sourceID: sourceID),
              storedTexts[sourceID] == nil, textsInFlight.insert(sourceID).inserted else { return }
        defer { textsInFlight.remove(sourceID) }
        let state: MnemonicReadingSourceText
        if backend.title(sourceID) == nil {
            state = .unavailable("This source is not on this iPhone.")
        } else {
            do {
                let text = try await backend.text(sourceID)
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    state = .unavailable("This source has no text yet.")
                } else {
                    storedTexts[sourceID] = text
                    // The questions as they stand now: the body may have
                    // grown while the text was read.
                    let questions = reading?.section(sourceID: sourceID)?.questions ?? section.questions
                    state = .loaded(await Self.layout(text: text, questions: questions))
                }
            } catch {
                state = .unavailable("This source's text has not reached this iPhone yet.")
            }
        }
        texts[sourceID] = state
        rebuildRows()
    }

    private nonisolated static func layout(text: String, questions: [MnemonicQuestion]) async -> MnemonicReadingLayout {
        await Task.detached(priority: .userInitiated) {
            MnemonicReadingPlacement.layout(text: text, questions: questions)
        }.value
    }

    /// Where every question stands, read again from what the phone holds.
    func refreshMemory() async {
        guard let questions = reading?.questions, !questions.isEmpty else {
            memory = [:]
            return
        }
        let held = await backend.held(Set(questions.map(\.memoryItemID)))
        heldItems = Dictionary(held.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // An answer written here and not yet in the catalog stays counted.
        let catalogIDs = Set(held.attempts.map(\.id))
        heldAttempts = held.attempts + heldAttempts.filter { !catalogIDs.contains($0.id) && heldItems[$0.memoryItemID] != nil }
        restand()
    }

    private func restand() {
        memory = MobileMnemonicReadingMemory.standing(
            of: reading?.questions ?? [],
            items: Array(heldItems.values),
            attempts: heldAttempts
        )
    }

    private func rebuildRows() {
        guard let reading else {
            rows = []
            return
        }
        rows = MnemonicReadingRows.rows(of: reading, texts: texts, titles: titles)
    }

    // MARK: Answering

    func reveal(_ questionID: String) {
        revealed.insert(questionID)
        currentQuestionID = questionID
    }

    /// A graded question folds to its quiet line; a tap opens it again.
    func toggleUnfolded(_ questionID: String) {
        if unfolded.contains(questionID) {
            unfolded.remove(questionID)
            revealed.remove(questionID)
        } else {
            unfolded.insert(questionID)
            currentQuestionID = questionID
        }
    }

    /// Forgot or Remembered, decided as the Mac's store decides it and
    /// written before the card folds. The first answer keeps the question as
    /// a card with this grade as its first attempt; a later one is written
    /// only while the card is due. A write that fails is said on the card.
    func answer(_ question: MnemonicQuestion, remembered: Bool) async {
        guard answering.insert(question.id).inserted else { return }
        defer { answering.remove(question.id) }
        answerErrors[question.id] = nil
        currentQuestionID = question.id
        let letGo = backend.keepAwake()
        defer { letGo() }
        do {
            let itemID = question.memoryItemID
            let held = heldItems[itemID]
            let decision = try MobileMnemonicReadingAnswer.decide(
                question,
                remembered: remembered,
                sittingKey: sittingKey,
                heldItem: held,
                history: heldAttempts.filter { $0.memoryItemID == itemID },
                sourceText: storedTexts[question.sourceID],
                at: backend.now()
            )
            switch decision {
            case .keep(let item, let attempt):
                let identities = backend.identity(question.sourceID).map { [$0] } ?? []
                switch try await backend.keep(item, identities, attempt) {
                case .kept:
                    heldItems[item.id] = item
                    heldAttempts.append(attempt)
                    await backend.noteKept(item, attempt)
                case .keptElsewhere(let existing, let outcome):
                    // Another device kept it first: this answer went on its
                    // item, or this sitting's was there already. Either way
                    // the card stands answered here until the zone delta
                    // brings its own copy.
                    Self.logger.info("A reading's card was kept elsewhere first: \(outcome.rawValue, privacy: .public)")
                    heldItems[existing.id] = existing
                    if !heldAttempts.contains(where: { $0.id == attempt.id }) { heldAttempts.append(attempt) }
                    await backend.noteKept(existing, attempt)
                }
            case .write(let attempt):
                guard let held else { return }
                let outcome = try await backend.write(attempt, MemoryTutorIdentity.immutableCurriculumFingerprint(held))
                if outcome == .recorded {
                    heldAttempts.append(attempt)
                    await backend.noteRecorded(attempt)
                }
            case .skip(let outcome):
                Self.logger.info("A reading's answer was not written: \(outcome.rawValue, privacy: .public)")
            }
            restand()
            revealed.remove(question.id)
            unfolded.remove(question.id)
        } catch {
            Self.logger.error("A reading's answer was not saved: \(error.localizedDescription, privacy: .public)")
            answerErrors[question.id] = "Your answer was not saved. \(error.localizedDescription)"
        }
    }
}

extension MobileMnemonicReadingModel.Backend {
    /// The phone's own: the Doc store, the synced catalog, CloudKit.
    @MainActor
    static func live(artifact: MobileCloudArtifact, vm: MobileAudioReviewViewModel) -> Self {
        Self(
            body: { try await MobileNotebookDocStore.shared.markdown(for: artifact) },
            text: { try await MobileCloudSourceTextStore.shared.loadSourceText(sourceID: $0) },
            title: { vm.sourcesByID[$0]?.title },
            identity: { sourceID in
                guard let source = vm.sourcesByID[sourceID] else { return nil }
                return MobileReviewSourceIdentityPayload(
                    sourceID: source.id,
                    url: source.url,
                    normalizedURL: source.normalizedURL ?? source.url.map(MobileURLNormalizer.normalize),
                    doi: source.doi,
                    publishedDOI: source.publishedDOI
                )
            },
            held: { await vm.mnemonicReadingHeld(itemIDs: $0) },
            keep: { item, identities, attempt in
                try await MobileMemoryAttemptRecorder.shared.recordKeeping(item, sourceIdentities: identities, firstAttempt: attempt)
            },
            write: { attempt, fingerprint in
                try await MobileMemoryAttemptRecorder.shared.recordSelfGraded(attempt, parentCurriculumFingerprint: fingerprint)
            },
            noteKept: { await vm.noteKeptReadingCard($0, firstAttempt: $1) },
            noteRecorded: { await vm.noteRecordedCardAnswer($0) },
            keepAwake: {
                let assertion = MobileBackgroundSaveAssertion(name: "mnemonic-reading-answer")
                return { assertion.end() }
            }
        )
    }
}

// MARK: - The view

/// The reading's hue, the Mac's sepia (`NotebookStudioHue.sepia`): a book's
/// page, deeper in light mode and lighter in dark.
enum MobileMnemonicReadingHue {
    static let glyph = color(light: 0x8D6E4B, dark: 0xD2B48C, lightAlpha: 1, darkAlpha: 1)
    static let wash = color(light: 0x8D6E4B, dark: 0xD2B48C, lightAlpha: 0.10, darkAlpha: 0.16)

    private static func color(light: UInt32, dark: UInt32, lightAlpha: CGFloat, darkAlpha: CGFloat) -> Color {
        Color(uiColor: UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let hex = isDark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: isDark ? darkAlpha : lightAlpha
            )
        })
    }
}

struct MobileMnemonicReadingView: View {
    let artifact: MobileCloudArtifact
    let notebook: MobileCloudNotebook?

    @EnvironmentObject private var vm: MobileAudioReviewViewModel
    @StateObject private var model: MobileMnemonicReadingModel
    /// A question Next asked for whose source was still being read.
    @State private var pendingScrollTarget: String?

    /// The Reader's body, Georgia at 18 points, and its spacing, scaled
    /// with Dynamic Type.
    private static let bodyFont = Font.custom("Georgia", size: 18, relativeTo: .body)
    @ScaledMetric(relativeTo: .body) private var lineSpacing: CGFloat = 8
    @ScaledMetric(relativeTo: .body) private var paragraphGap: CGFloat = 14

    init(artifact: MobileCloudArtifact, notebook: MobileCloudNotebook?, vm: MobileAudioReviewViewModel) {
        self.artifact = artifact
        self.notebook = notebook
        _model = StateObject(wrappedValue: MobileMnemonicReadingModel(
            readingID: artifact.id,
            fallbackTitle: artifact.title,
            backend: .live(artifact: artifact, vm: vm)
        ))
    }

    /// The Reader's measure, about 34 of its ems.
    private static let columnWidth: CGFloat = 640

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    masthead(proxy)
                        .id("masthead")
                    ForEach(model.rows) { row in
                        rowView(row)
                            .id(row.id)
                    }
                    if let message = model.loadError {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.top, MobileDesign.Spacing.xLarge)
                    }
                }
                .frame(maxWidth: Self.columnWidth, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, MobileDesign.Spacing.medium)
                .padding(.bottom, 72)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: model.rows.map(\.id)) { _, ids in
                guard let target = pendingScrollTarget else { return }
                let rowID = MnemonicReadingRow.questionRowID(target)
                guard ids.contains(rowID) else { return }
                pendingScrollTarget = nil
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(rowID, anchor: .center) }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(model.reading?.title ?? artifact.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: artifact.bodyRevision ?? artifact.id) {
            await model.load()
        }
        .onChange(of: vm.memoryCardsRevision) { _, _ in
            Task { await model.refreshMemory() }
        }
        .accessibilityIdentifier("mnemonicReading")
    }

    // MARK: Masthead

    private func masthead(_ proxy: ScrollViewProxy) -> some View {
        let counts = model.counts()
        return VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
            Text(MnemonicReading.kindLabel)
                .font(.caption.weight(.semibold))
                .kerning(0.8)
                .textCase(.uppercase)
                .foregroundStyle(MobileMnemonicReadingHue.glyph)
            Text(model.reading?.title ?? artifact.title)
                .font(.system(.title, design: .serif).weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: MobileDesign.Spacing.medium) {
                    countsLine(counts)
                    Spacer(minLength: MobileDesign.Spacing.small)
                    nextButton(counts, proxy)
                }
                VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
                    countsLine(counts)
                    nextButton(counts, proxy)
                }
            }
            progressBar(counts)
                .padding(.top, MobileDesign.Spacing.xSmall)
                .padding(.bottom, MobileDesign.Spacing.small)
        }
    }

    private func countsLine(_ counts: MnemonicReadingProgress.Counts) -> some View {
        Text(MnemonicReadingProgress.line(counts))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .accessibilityIdentifier("mnemonicReading.counts")
    }

    @ViewBuilder
    private func nextButton(_ counts: MnemonicReadingProgress.Counts, _ proxy: ScrollViewProxy) -> some View {
        if counts.answered < counts.questions {
            Button {
                goToNextQuestion(proxy)
            } label: {
                Label("Next Question", systemImage: "arrow.down")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(MobileMnemonicReadingHue.glyph)
            .hoverEffect(.highlight)
            .accessibilityHint("Goes to the next question not answered yet")
            .accessibilityIdentifier("mnemonicReading.next")
        }
    }

    /// How much of the reading is answered, a hairline in the reading's hue.
    private func progressBar(_ counts: MnemonicReadingProgress.Counts) -> some View {
        GeometryReader { geometry in
            let share = counts.questions == 0 ? 0 : CGFloat(counts.answered) / CGFloat(counts.questions)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(MobileMnemonicReadingHue.glyph.opacity(0.75))
                    .frame(width: max(0, geometry.size.width * share))
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }

    private func goToNextQuestion(_ proxy: ScrollViewProxy) {
        guard let id = model.nextUnansweredQuestionID() else { return }
        model.currentQuestionID = id
        let rowID = MnemonicReadingRow.questionRowID(id)
        if model.rows.contains(where: { $0.id == rowID }) {
            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(rowID, anchor: .center) }
        } else if let sourceID = model.sourceID(ofQuestion: id) {
            // Its chapter is not read yet: go to its place, read it, then on
            // to the question once its rows are there.
            pendingScrollTarget = id
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(MnemonicReadingRow.headingRowID(sourceID), anchor: .top)
            }
            Task { await model.loadText(of: sourceID) }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func rowView(_ row: MnemonicReadingRow) -> some View {
        switch row {
        case .heading(let sourceID, let title):
            sourceHeading(sourceID: sourceID, title: title)
        case .pending:
            Text("No questions yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.bottom, MobileDesign.Spacing.medium)
        case .loading(let sourceID):
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 140)
                // Read once its place has stayed in view a moment: a jump
                // past many chapters reads only the one it lands on.
                .task(id: sourceID) {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    await model.loadText(of: sourceID)
                }
        case .unavailable(_, let reason):
            Text(reason)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, paragraphGap)
        case .block(_, let block):
            blockView(block)
        case .question(let question, let isUnplaced):
            MobileMnemonicQuestionCard(question: question, isUnplaced: isUnplaced, model: model)
                .padding(.top, MobileDesign.Spacing.xSmall)
                .padding(.bottom, paragraphGap + MobileDesign.Spacing.small)
        }
    }

    @ViewBuilder
    private func sourceHeading(sourceID: String, title: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: MobileDesign.Spacing.small) {
            Text(title)
                .font(.system(.title2, design: .serif).weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if vm.sourcesByID[sourceID] != nil {
                NavigationLink(value: MobileShellRoute.source(sourceID, notebookID: notebook?.id)) {
                    Image(systemName: "book")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: MobileDesign.Metrics.minimumTouchTarget, height: MobileDesign.Metrics.minimumTouchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("Open \(title) in the Reader")
            }
        }
        .padding(.top, 28)
        .padding(.bottom, MobileDesign.Spacing.medium)
    }

    @ViewBuilder
    private func blockView(_ block: MnemonicReadingBlock) -> some View {
        switch block.kind {
        case .paragraph:
            prose(block.text)
                .padding(.bottom, paragraphGap)
        case .heading(let level):
            Text(Self.inline(block.text))
                .font(Self.headingFont(level))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, level <= 2 ? 18 : 12)
                .padding(.bottom, MobileDesign.Spacing.small)
                .accessibilityAddTraits(.isHeader)
        case .listItem(let marker):
            HStack(alignment: .firstTextBaseline, spacing: MobileDesign.Spacing.small) {
                Text(["-", "*", "+", "\u{2022}"].contains(marker) ? "\u{2022}" : marker)
                    .font(Self.bodyFont)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                prose(block.text)
            }
            .padding(.bottom, paragraphGap / 2)
        case .figure:
            Text(block.text)
                .font(.custom("Georgia", size: 16, relativeTo: .body).italic())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, paragraphGap)
        case .rule:
            Text("\u{2042}")
                .font(.title3)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, MobileDesign.Spacing.medium)
                .accessibilityHidden(true)
        }
    }

    /// A paragraph in the Reader's face: Georgia, its inline Markdown drawn.
    private func prose(_ text: String) -> some View {
        Text(Self.inline(text))
            .font(Self.bodyFont)
            .lineSpacing(lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    /// The Reader's headings, in its sans face, scaled with Dynamic Type.
    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2.weight(.semibold)
        case 2: return .title3.weight(.semibold)
        default: return .headline
        }
    }
}

/// One question in the reading. Unanswered: the question and **Show Answer**;
/// turned over: the answer, why it holds, then **Forgot** and **Remembered**.
/// Answered: one quiet line — the question, its grade, when it comes back —
/// that opens again on a tap, where a card due now can be graded again and
/// any other shows its answer and when it comes back.
private struct MobileMnemonicQuestionCard: View {
    let question: MnemonicQuestion
    let isUnplaced: Bool
    @ObservedObject var model: MobileMnemonicReadingModel

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var memory: MnemonicQuestionMemory? { model.memory[question.id] }
    private var isRevealed: Bool { model.revealed.contains(question.id) }
    private var isUnfolded: Bool { model.unfolded.contains(question.id) }
    private var isAnswering: Bool { model.answering.contains(question.id) }

    var body: some View {
        if let memory, !isUnfolded {
            foldedLine(memory)
        } else {
            card
        }
    }

    // MARK: Answered, folded

    private func foldedLine(_ memory: MnemonicQuestionMemory) -> some View {
        let standing = MobileMnemonicReadingMemory.standingLine(memory)
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { model.toggleUnfolded(question.id) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: MobileDesign.Spacing.small) {
                Image(systemName: Self.glyph(memory))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(MobileMnemonicReadingHue.glyph)
                VStack(alignment: .leading, spacing: 2) {
                    Text(question.question)
                        .font(.subheadline)
                        .foregroundStyle(.primary.opacity(0.8))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(standing)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, MobileDesign.Spacing.medium)
            .padding(.vertical, MobileDesign.Spacing.small)
            .frame(minHeight: MobileDesign.Metrics.minimumTouchTarget)
            .background(
                RoundedRectangle(cornerRadius: MobileDesign.Radius.compact, style: .continuous)
                    .fill(MobileMnemonicReadingHue.wash.opacity(0.6))
            )
            .contentShape(RoundedRectangle(cornerRadius: MobileDesign.Radius.compact, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Question: \(question.question)")
        .accessibilityValue(standing)
        .accessibilityHint("Shows it again")
        .accessibilityIdentifier("mnemonicReading.folded")
    }

    private static func glyph(_ memory: MnemonicQuestionMemory) -> String {
        if memory.isRetired { return "minus.circle" }
        return memory.lastRemembered == false ? "arrow.counterclockwise" : "checkmark"
    }

    // MARK: The card

    private var card: some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.medium) {
            HStack(spacing: MobileDesign.Spacing.xSmall) {
                Text("Question")
                    .font(.caption2.weight(.semibold))
                    .kerning(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(MobileMnemonicReadingHue.glyph)
                if isUnplaced {
                    Text("· passage not found")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if memory != nil {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { model.toggleUnfolded(question.id) }
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: MobileDesign.Metrics.minimumTouchTarget, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)
                    .accessibilityLabel("Fold")
                }
            }

            Text(question.question)
                .font(.body.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Question: \(question.question)")
                .accessibilityIdentifier("mnemonicReading.question")

            if isRevealed || (memory.map { !model.isDue($0) } ?? false) {
                answer
            }
            controls
            if let error = model.answerErrors[question.id] {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(MobileDesign.Spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: MobileDesign.Radius.card, style: .continuous)
                .fill(MobileMnemonicReadingHue.wash)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileDesign.Radius.card, style: .continuous)
                .strokeBorder(MobileMnemonicReadingHue.glyph.opacity(0.18), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mnemonicReading.card")
    }

    private var answer: some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
            Divider()
            Text(MobileMnemonicReadingView.inline(question.answer))
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Answer: \(question.answer)")
            if let why = question.why {
                Text(why)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        if let memory, !model.isDue(memory) {
            // Kept, and not due: the reading says when it comes back and
            // writes nothing.
            Text(MobileMnemonicReadingMemory.standingLine(memory))
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if !isRevealed {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { model.reveal(question.id) }
            } label: {
                Text("Show Answer")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(MobileMnemonicReadingHue.glyph)
            .hoverEffect(.highlight)
            .accessibilityIdentifier("mnemonicReading.show")
        } else if model.canAnswer(question.id) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: MobileDesign.Spacing.small))
                : AnyLayout(HStackLayout(spacing: MobileDesign.Spacing.medium))
            layout {
                Button {
                    grade(remembered: false)
                } label: {
                    Text("Forgot")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)
                .hoverEffect(.highlight)
                .accessibilityIdentifier("mnemonicReading.forgot")
                Button {
                    grade(remembered: true)
                } label: {
                    Text("Remembered")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .hoverEffect(.highlight)
                .accessibilityIdentifier("mnemonicReading.remembered")
            }
            .buttonBorderShape(.capsule)
            .tint(MobileMnemonicReadingHue.glyph)
            .disabled(isAnswering)
            .overlay {
                if isAnswering { ProgressView() }
            }
        } else {
            Text("Its passage is no longer in this text, so it cannot be kept.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func grade(remembered: Bool) {
        let question = question
        let model = model
        Task {
            await model.answer(question, remembered: remembered)
        }
    }
}
