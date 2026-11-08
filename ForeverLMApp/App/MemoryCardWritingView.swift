#if os(macOS)
import SwiftUI

/// The card the learner writes beside its source (`WrittenCard.swift`,
/// docs/memory-design.md, "Writing a source's card"): drawn as the card it
/// becomes — the question in the review's serif, the fold, the answer in
/// their own words — with the passage it stands on under it, taken from the
/// Reader's selection. One dark pill saves it; Next Source moves the Reader
/// on when Make Cards named several. The Memory pane shows it in place of
/// its sections while the window is writing (`StudioWindowState.cardWriting`).
struct MemoryCardWritingView: View {
    let session: CardWritingSession
    let windowState: StudioWindowState

    @Environment(StudioViewModel.self) private var vm
    @State private var input = WrittenCardInput()
    @State private var problem: String?
    @State private var isSaving = false
    @State private var justSaved = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                card
                    .padding(.bottom, 4)

                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.disabled)
                        .padding(.top, 14)
                        .accessibilityIdentifier("memory.write.problem")
                } else if justSaved {
                    Text(savedLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.disabled)
                        .padding(.top, 14)
                        .accessibilityIdentifier("memory.write.saved")
                }

                HStack(spacing: 8) {
                    if session.isLast {
                        MemoryReviewButton(title: "Done", kind: .quiet) {
                            vm.endCardWriting(in: windowState)
                        }
                        .accessibilityIdentifier("memory.write.done")
                    } else {
                        MemoryReviewButton(title: "Next Source", kind: .quiet) {
                            Task { await vm.writeCardsNextSource(in: windowState) }
                        }
                        .help(session.savedHere == 0 ? "Leave this source without a card for now" : "Write the next source's card")
                        .accessibilityIdentifier("memory.write.next")
                    }
                    Spacer()
                    MemoryReviewButton(
                        title: "Save Card",
                        kind: .primary,
                        minWidth: 120,
                        shortcut: KeyboardShortcut(.return, modifiers: .command)
                    ) {
                        save()
                    }
                    .disabled(input.missing != nil || isSaving)
                    .help(input.missing?.help ?? "Keep this card (⌘↩)")
                    .accessibilityIdentifier("memory.write.save")
                }
                .padding(.top, 22)
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 28)
            .padding(.top, 32)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("memory.write")
    }

    // MARK: The card

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            MemoryCardTagLine(tags: tags)
                .padding(.bottom, 12)
            MemoryCardEditorField(
                text: $input.front, prompt: "The question", font: MemoryCardMetrics.frontFont, label: "Question",
                identifier: "memory.write.front"
            )
            MemoryCardFold()
                .padding(.vertical, 12)
            MemoryCardEditorField(
                text: $input.back, prompt: "The answer, in your own words", font: MemoryCardMetrics.backFont,
                label: "Answer", identifier: "memory.write.back"
            )
            passage
                .padding(.top, 16)
        }
        .padding(.horizontal, 30)
        .padding(.top, 24)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .memoryCardSurface()
        .onChange(of: input) { _, _ in
            if problem != nil { problem = nil }
            if justSaved, !input.isEmpty { justSaved = false }
        }
    }

    private var tags: [String] {
        var tags = [vm.writingSourceTitle(session)]
        if let progress = session.progressLabel { tags.append(progress) }
        return tags
    }

    /// The passage the card stands on: the words taken from the Reader, or
    /// how to take them.
    private var passage: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if input.passage.isEmpty {
                Text("Select the passage it stands on in the source")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                Text("\u{201C}\(input.passage)\u{201D}")
                    .font(.callout.italic())
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Passage")
                    .accessibilityValue(input.passage)
            }
            Spacer(minLength: 8)
            Button(input.passage.isEmpty ? "Use Selection" : "Replace") {
                useSelection()
            }
            .buttonStyle(.hoverWash(in: Capsule(), inset: 0, opacity: 0.07))
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.secondary)
            .help("Take the passage selected in the Reader")
            .accessibilityIdentifier("memory.write.useSelection")
        }
        .textSelection(.disabled)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: input.passage.isEmpty ? [3, 4] : []))
        )
    }

    private var savedLine: String {
        let count = session.savedHere
        let cards = count == 1 ? "1 card" : "\(count) cards"
        return session.isLast ? "Saved: \(cards) for this source. Write another, or Done." : "Saved: \(cards) for this source. Write another, or Next Source."
    }

    // MARK: Actions

    private func useSelection() {
        guard let words = vm.writingPassageFromSelection(session) else {
            problem = "Nothing is selected in \u{201C}\(vm.writingSourceTitle(session))\u{201D}. Select the passage in the Reader first."
            return
        }
        input.passage = words
    }

    private func save() {
        guard input.missing == nil, !isSaving else { return }
        isSaving = true
        let written = input
        Task {
            let failure = await vm.saveWrittenCard(written, in: windowState)
            isSaving = false
            if let failure {
                problem = failure
            } else {
                input = WrittenCardInput()
                justSaved = true
            }
        }
    }
}
#endif
