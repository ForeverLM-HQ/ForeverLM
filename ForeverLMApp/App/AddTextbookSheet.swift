import SwiftUI

/// Which course the Add Textbook sheet plans into, and the book it opens on
/// when one was dropped on the course.
struct TextbookSheetTarget: Identifiable {
    let courseID: String
    let bookID: String?
    var id: String { courseID }
}

/// The sheet behind a course's **Add Textbook…**: pick a library book and
/// ForeverLM places the parts of the book worth reading after each lecture,
/// optionally tailored by what the learner says (docs/textbook-readings-design.md).
///
/// The planning runs in `TextbookReadingService`; this view collects the
/// book and the learner's words, shows the stage while it runs, and closes
/// when the readings are in the course.
struct AddTextbookSheet: View {
    var vm: StudioViewModel
    let target: TextbookSheetTarget
    @Environment(\.dismiss) private var dismiss

    @State private var bookID: String?
    @State private var aboutYou = ""
    @State private var focus = ""
    @State private var errorMessage: String?
    @State private var planTask: Task<Void, Never>?

    private var isPlanning: Bool { planTask != nil }

    private var canPlan: Bool {
        bookID != nil
            && !isPlanning
    }

    /// Books the library holds, by display title.
    private var books: [(id: String, label: String)] {
        vm.visibleBookGroupNames.map { id in
            let title = vm.bookDisplayName(id)
            if let author = vm.bookDisplayAuthor(id)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !author.isEmpty {
                return (id, "\(title) — \(author)")
            }
            return (id, title)
        }
    }

    /// Planning a book the course already reads from replaces its readings.
    private var replaces: Bool {
        bookID.map { vm.textbookIDs(inCourse: target.courseID).contains($0) } ?? false
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(isPlanning ? "Stop" : "Cancel") {
                    if isPlanning {
                        planTask?.cancel()
                        planTask = nil
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Text("Add a Textbook").font(.headline)
                Spacer()
                Button(replaces ? "Replace Readings" : "Add Readings") { plan() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canPlan)
                    .accessibilityIdentifier("textbook-sheet.add")
            }
            .padding()

            Divider()

            // Course and Book are rows; the two answers are boxes of their
            // own under them. A grouped Form drew them as borderless,
            // right-aligned fields whose prompts read like filled-in values.
            VStack(alignment: .leading, spacing: 16) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Course")
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        Text(vm.courseDisplayName(target.courseID))
                            .lineLimit(2)
                    }
                    GridRow {
                        Text("Book")
                            .foregroundStyle(.secondary)
                        Picker("Book", selection: $bookID) {
                            Text("Choose a book").tag(String?.none)
                            ForEach(books, id: \.id) { book in
                                Text(book.label).tag(Optional(book.id))
                            }
                        }
                        .labelsHidden()
                        .accessibilityIdentifier("textbook-sheet.book")
                    }
                }

                answerBox(
                    "About you",
                    note: "Optional",
                    prompt: "Where you're coming from: your background, what you know well, what's new to you",
                    text: $aboutYou,
                    lines: 3...8
                )
                .accessibilityIdentifier("textbook-sheet.about-you")

                answerBox(
                    "From this course",
                    note: "Optional",
                    prompt: "What you need from it",
                    text: $focus,
                    lines: 2...4
                )
                .accessibilityIdentifier("textbook-sheet.focus")
            }
            .padding(20)
            .disabled(isPlanning)

            if isPlanning || errorMessage != nil {
                Divider()
                statusRow
            }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: prefill)
        .onDisappear {
            planTask?.cancel()
            planTask = nil
        }
    }

    /// A labelled, bordered, left-aligned box for a free-text answer.
    private func answerBox(
        _ title: String,
        note: String,
        prompt: String,
        text: Binding<String>,
        lines: ClosedRange<Int>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            TextField(title, text: text, prompt: Text(prompt), axis: .vertical)
                .textFieldStyle(.plain)
                .labelsHidden()
                .lineLimit(lines)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(nsColor: .separatorColor))
                )
        }
        // A group of its own, so the caller's identifier names the box: on a
        // plain container it landed on both texts and the field.
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 10) {
            if isPlanning {
                ProgressView()
                    .controlSize(.small)
                Text((vm.textbookReadingStages[target.courseID] ?? .fetchingTranscripts).label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let errorMessage {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// The learner's saved words, and the book: the one dropped, else the one
    /// the course already reads from. A take in Screen record mode starts
    /// blank, so the learner's own background never reaches a recording.
    private func prefill() {
        let courseBooks = vm.textbookIDs(inCourse: target.courseID)
        bookID = target.bookID ?? (courseBooks.count == 1 ? courseBooks.first : nil)
        if !ScreenRecordMode.isEffective {
            aboutYou = LearnerProfile.aboutYou
            focus = LearnerProfile.courseFocus(courseID: target.courseID)
        }
    }

    private func plan() {
        guard let bookID, canPlan else { return }
        errorMessage = nil
        let courseID = target.courseID
        let aboutYou = aboutYou
        let focus = focus
        let vm = vm
        planTask = Task { @MainActor in
            do {
                let result = try await vm.addTextbookReadings(
                    courseID: courseID,
                    bookID: bookID,
                    aboutYou: aboutYou,
                    focus: focus
                )
                guard !Task.isCancelled else { return }
                planTask = nil
                vm.showToast(StudioViewModel.textbookReadingSummary(result, courseTitle: vm.courseDisplayName(courseID)))
                dismiss()
            } catch is CancellationError {
                planTask = nil
            } catch {
                planTask = nil
                errorMessage = error.localizedDescription
            }
        }
    }
}
