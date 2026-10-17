#if os(macOS)
import SwiftUI

/// A mnemonic reading, open where a notebook's output opens — the Docs
/// canvas, its document slot inside a notebook (docs/memory-design.md,
/// "Mnemonic reading"): each source in order under its title, its own stored
/// text set as the Reader's prose form sets it — the serif face, its measure
/// and its spacing — and after the paragraph that holds a question's quote,
/// the question. **Show Answer** turns it over; **Forgot** or **Remembered**
/// keeps it as a Memory card and folds it to one quiet line, which opens again
/// on a click. Its text is read chapter by chapter as it scrolls into view,
/// never the whole book at once, and nothing is read or written on the main
/// actor (`MnemonicReadingModel`).
struct MnemonicReadingView: View {
    let artifact: ArtifactRecord

    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    @ObservedObject private var writer = MnemonicReadingCoordinator.shared
    @State private var model: MnemonicReadingModel
    /// A question Next asked for whose source was still being read.
    @State private var pendingScrollTarget: String?

    init(artifact: ArtifactRecord) {
        self.artifact = artifact
        _model = State(initialValue: MnemonicReadingModel(readingID: artifact.id))
    }

    private static let hue = NotebookStudioHue.sepia
    private var bodyFont: NSFont { ProseReaderTypography.bodyFont(zoomScale: 1) }
    private var lineSpacing: CGFloat { (bodyFont.pointSize * (ProseReaderTypography.lineHeightMultiple - 1)).rounded() }
    private var paragraphGap: CGFloat { (bodyFont.pointSize * 0.7).rounded() }

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
                            .textSelection(.disabled)
                            .padding(.top, 24)
                    }
                }
                .frame(maxWidth: ProseReaderTypography.columnWidth(for: bodyFont), alignment: .leading)
                .padding(.horizontal, ProseReaderTypography.minimumSideMargin)
                .padding(.top, ProseReaderTypography.topPadding)
                .padding(.bottom, 96)
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
        .task(id: artifact.updatedAt) {
            await model.load(storage: vm.storage)
        }
        .onChange(of: vm.memoryCardRevision) { _, _ in
            Task { await model.refreshMemory(storage: vm.storage) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(artifact.title)
        .accessibilityIdentifier("mnemonic-reading")
    }

    // MARK: Masthead

    private func masthead(_ proxy: ScrollViewProxy) -> some View {
        let counts = model.counts()
        let run = writer.run(artifact.id)
        return VStack(alignment: .leading, spacing: 10) {
            Text(MnemonicReading.kindLabel.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(1.1)
                .foregroundStyle(Self.hue.glyph)
                .textSelection(.disabled)
            Text(model.reading?.title ?? artifact.title)
                .font(Font(ProseReaderTypography.serif(size: ProseReaderTypography.titlePointSize, weight: .medium)))
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .center, spacing: 10) {
                Text(MnemonicReadingProgress.line(counts))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .textSelection(.disabled)
                if let run {
                    ProgressView().controlSize(.small)
                    Text(run.progress.label)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.disabled)
                }
                Spacer(minLength: 8)
                if counts.answered < counts.questions {
                    Button {
                        goToNextQuestion(proxy)
                    } label: {
                        Label("Next Question", systemImage: "arrow.down")
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.hoverWash(in: Capsule(), inset: 0))
                    .help("Go to the next question not answered yet")
                    .accessibilityIdentifier("mnemonic-reading.next")
                }
            }
            progressBar(counts)
                .padding(.bottom, ProseReaderTypography.mastheadGap - 8)
        }
    }

    /// How much of the reading is answered, a hairline in the reading's hue.
    private func progressBar(_ counts: MnemonicReadingProgress.Counts) -> some View {
        GeometryReader { geometry in
            let share = counts.questions == 0 ? 0 : CGFloat(counts.answered) / CGFloat(counts.questions)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(Self.hue.glyph.opacity(0.75))
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
            Task { await model.loadText(of: sourceID, storage: vm.storage) }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func rowView(_ row: MnemonicReadingRow) -> some View {
        switch row {
        case .heading(let sourceID, let title):
            sourceHeading(sourceID: sourceID, title: title)
        case .pending(let sourceID):
            pendingRow(sourceID: sourceID)
        case .loading(let sourceID):
            HStack {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            }
            .frame(height: 160)
            // Read once its place has stayed in view a moment: a jump past
            // many chapters reads only the one it lands on, so nothing above
            // the page grows under the reader.
            .task(id: sourceID) {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await model.loadText(of: sourceID, storage: vm.storage)
            }
        case .unavailable(_, let reason):
            Text(reason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.disabled)
                .padding(.bottom, paragraphGap)
        case .block(_, let block):
            blockView(block)
        case .question(let question, let isUnplaced):
            MnemonicQuestionCard(
                question: question,
                isUnplaced: isUnplaced,
                model: model,
                storage: vm.storage,
                onAnswered: { vm.memoryCardRevision &+= 1 }
            )
            .padding(.top, 4)
            .padding(.bottom, paragraphGap + 8)
        }
    }

    private func sourceHeading(sourceID: String, title: String) -> some View {
        Text(title)
            .font(Font(ProseReaderTypography.serif(size: 22, weight: .semibold)))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 28)
            .padding(.bottom, 16)
            .accessibilityAddTraits(.isHeader)
            .contextMenu {
                Button("Open in Reader", systemImage: "book") {
                    Task { await vm.openLinkedSourceInReader(sourceID, beside: .notepad) }
                }
                OtherWindowSourceMenuItem(sourceID: sourceID)
            }
    }

    @ViewBuilder
    private func pendingRow(sourceID: String) -> some View {
        HStack(spacing: 10) {
            if writer.run(artifact.id) != nil {
                ProgressView().controlSize(.small)
                Text("Writing questions")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.disabled)
            } else {
                Text("No questions yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.disabled)
                if canWriteQuestions {
                    Button("Write Questions") {
                        vm.inWindow(windowState) {
                            vm.presentPendingMnemonicReadingQuestions(
                                readingID: artifact.id,
                                sourceIDs: model.reading?.pendingSourceIDs ?? [sourceID],
                                notebookID: artifact.homeNotebookID
                            )
                        }
                    }
                    .buttonStyle(.hoverWash)
                    .font(.callout.weight(.medium))
                    .help("Write the questions of the sources still waiting for theirs")
                    .accessibilityIdentifier("mnemonic-reading.write")
                }
            }
        }
        .padding(.bottom, 14)
    }

    /// A reading of the open library this account can change.
    private var canWriteQuestions: Bool {
        !vm.isActiveLibraryReadOnly && (artifact.teamID == nil || artifact.teamID == vm.activeTeamID)
    }

    @ViewBuilder
    private func blockView(_ block: MnemonicReadingBlock) -> some View {
        switch block.kind {
        case .paragraph:
            prose(block.text)
                .padding(.bottom, paragraphGap)
        case .heading(let level):
            Text(Self.inline(block.text))
                .font(.system(size: Self.headingSize(level), weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, level <= 2 ? 18 : 12)
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
        case .listItem(let marker):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(["-", "*", "+", "\u{2022}"].contains(marker) ? "\u{2022}" : marker)
                    .font(Font(bodyFont))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 18, alignment: .trailing)
                    .textSelection(.disabled)
                prose(block.text)
            }
            .padding(.bottom, paragraphGap / 2)
        case .figure:
            Text(block.text)
                .font(Font(ProseReaderTypography.serif(size: bodyFont.pointSize - 2)))
                .italic()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, paragraphGap)
        case .rule:
            Text("\u{2042}")
                .font(.title3)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .textSelection(.disabled)
                .accessibilityHidden(true)
        }
    }

    /// A paragraph in the Reader's prose face: its inline Markdown (emphasis,
    /// links) drawn, its measure the column's.
    private func prose(_ text: String) -> some View {
        Text(Self.inline(text))
            .font(Font(bodyFont))
            .lineSpacing(lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    /// A Markdown heading's size, as the Reader's book style sets h1 to h4.
    static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 24
        case 2: return 21
        case 3: return 19
        default: return 17
        }
    }
}

/// One question in the reading. Unanswered: the question and **Show Answer**;
/// turned over: the answer, why it is right, smaller, then **Forgot** and
/// **Remembered**. Answered: one quiet line — the question, its grade, when it
/// comes back — that opens again on a click, where a card due now can be
/// graded again and any other shows its answer.
struct MnemonicQuestionCard: View {
    let question: MnemonicQuestion
    let isUnplaced: Bool
    let model: MnemonicReadingModel
    let storage: StorageService
    let onAnswered: () -> Void

    private static let hue = NotebookStudioHue.sepia

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
        Button {
            model.toggleUnfolded(question.id)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: Self.glyph(memory))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Self.hue.glyph)
                    .frame(width: 14)
                Text(question.question)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary.opacity(0.75))
                Spacer(minLength: 8)
                Text(Self.standing(memory))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.hoverWash(cornerRadius: 8, inset: 0))
        .textSelection(.disabled)
        .help("Show this question again")
        .accessibilityLabel("Question: \(question.question). \(Self.standing(memory))")
    }

    private static func glyph(_ memory: MnemonicQuestionMemory) -> String {
        if memory.isRetired { return "minus.circle" }
        return memory.lastRemembered == false ? "arrow.counterclockwise" : "checkmark"
    }

    /// "Remembered · back in 4 days", "Forgot · due now", "Retired".
    static func standing(_ memory: MnemonicQuestionMemory, now: Date = Date()) -> String {
        if memory.isRetired { return "Retired" }
        let grade = memory.lastRemembered == false ? "Forgot" : "Remembered"
        if memory.isDue(at: now) { return "\(grade) · due now" }
        let when = memory.dueAt.formatted(.relative(presentation: .named, unitsStyle: .wide))
        return "\(grade) · back \(when)"
    }

    // MARK: The card

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("QUESTION")
                    .font(.system(size: 10.5, weight: .semibold))
                    .kerning(1)
                    .foregroundStyle(Self.hue.glyph)
                if isUnplaced {
                    Text("· passage not found")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if memory != nil {
                    Button {
                        model.toggleUnfolded(question.id)
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.hoverWash(cornerRadius: 5, inset: 0))
                    .help("Fold this question")
                    .accessibilityLabel("Fold")
                }
            }
            .textSelection(.disabled)

            Text(question.question)
                .font(.system(size: 15.5, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)

            if isRevealed || (memory != nil && !(memory?.isDue(at: Date()) ?? false)) {
                answer
            }
            controls
            if let error = model.answerErrors[question.id] {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.disabled)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Self.hue.wash)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Self.hue.glyph.opacity(0.18), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Question")
    }

    private var answer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.vertical, 2)
            Text(MnemonicReadingView.inline(question.answer))
                .font(.system(size: 15))
                .fixedSize(horizontal: false, vertical: true)
            if let why = question.why {
                Text(why)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        let dueNow = memory?.isDue(at: Date()) ?? true
        if let memory, !dueNow {
            // Kept, and not due: the reading shows when it comes back and
            // writes nothing.
            Text(Self.standing(memory))
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.disabled)
        } else if !isRevealed {
            HStack {
                Spacer()
                capsule("Show Answer", prominent: true) { model.reveal(question.id) }
                    .accessibilityIdentifier("mnemonic-reading.show")
            }
        } else if model.canAnswer(question.id) {
            HStack(spacing: 10) {
                Spacer()
                if isAnswering { ProgressView().controlSize(.small) }
                capsule("Forgot", prominent: false) { answer(remembered: false) }
                    .accessibilityIdentifier("mnemonic-reading.forgot")
                capsule("Remembered", prominent: true) { answer(remembered: true) }
                    .accessibilityIdentifier("mnemonic-reading.remembered")
            }
            .disabled(isAnswering)
        } else {
            Text("Its passage is no longer in this text, so it cannot be kept.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.disabled)
        }
    }

    private func answer(remembered: Bool) {
        let question = question
        let model = model
        let storage = storage
        let onAnswered = onAnswered
        Task {
            if await model.answer(question, remembered: remembered, storage: storage) != nil {
                onAnswered()
            }
        }
    }

    /// The card review's capsule, a size smaller: filled for the one that
    /// moves on.
    private func capsule(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .frame(minWidth: 96, minHeight: 28)
                .padding(.horizontal, 12)
                .background(
                    Capsule().fill(prominent ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                )
                .overlay(Capsule().strokeBorder(Color.primary.opacity(prominent ? 0 : 0.14), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.hoverWash(in: Capsule(), inset: 0, opacity: prominent ? 0.18 : 0.08))
    }
}
#endif
