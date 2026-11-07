#if os(macOS)
import Foundation

// MARK: - Mnemonic readings: making one
//
// docs/memory-design.md, "Mnemonic reading". Make Mnemonic Reading asks first
// and makes on the second press, as every Studio tile does: the Reader's ⋯
// (its source, a book's chapter, or the whole book) opens the sheet — what it
// reads, Fewer · Auto · More, the price — whose Make writes the questions in the background (`MnemonicReadingCoordinator`).
// The reading opens in a pane once its first source is written. It is
// made from one source at a time, never from a notebook's ticked sources (product
// owner, 2026-10-17: it "does apply to individual sources").

extension StudioViewModel {

    // MARK: The sheet

    /// Make Mnemonic Reading's first press: the sheet for `sourceIDs`, in
    /// reading order, in the active window (`MakeMnemonicReadingSheet`).
    /// `notebookID` is the notebook it is made in, nil from a Reader outside
    /// a notebook; `bookSourceIDs` the whole book's chapters when the sheet
    /// is asked from one of them; `readingID` a reading whose pending sources
    /// are written again.
    func presentMnemonicReading(
        notebookID: String?,
        sourceIDs: [String],
        bookSourceIDs: [String]? = nil,
        readingID: String? = nil
    ) {
        var seen = Set<String>()
        let ids = sourceIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !ids.isEmpty else {
            showToast("Open a source to read it with questions")
            return
        }
        MnemonicReadingCoordinator.shared.present(MnemonicReadingTarget(
            notebookID: notebookID,
            sourceIDs: ids,
            bookSourceIDs: bookSourceIDs,
            readingID: readingID,
            windowID: activeWindowState.id
        ))
    }

    /// The Reader's Make Mnemonic Reading…: its source, and for a book's
    /// chapter the whole book in reading order as the sheet's other choice,
    /// in the notebook `windowState` holds when the source is one of the
    /// notebook's.
    func presentReaderMnemonicReading(sourceID: String, in windowState: StudioWindowState) {
        let notebookID = windowState.notebook?.notebookID
        let inNotebook = notebookID.map { notebookHolds($0, sourceID: sourceID) } ?? false
        var book: [String]?
        if let article = articlesById[sourceID], article.sourceType == .book,
           let group = article.parentGroup, !group.isEmpty {
            let chapters = bookChapterArticlesInOrder(for: group).map(\.id)
            if chapters.count > 1, chapters.contains(sourceID) { book = chapters }
        }
        inWindow(windowState) {
            presentMnemonicReading(notebookID: inNotebook ? notebookID : nil, sourceIDs: [sourceID], bookSourceIDs: book)
        }
    }

    /// The reading's own Write Questions: the sheet for its pending sources,
    /// written into it.
    func presentPendingMnemonicReadingQuestions(readingID: String, sourceIDs: [String], notebookID: String?) {
        presentMnemonicReading(notebookID: notebookID, sourceIDs: sourceIDs, readingID: readingID)
    }

    // MARK: Making

    /// The sheet's Make: the plan it priced, written in the background, the
    /// reading opened in the window it was asked from.
    @discardableResult
    func makeMnemonicReading(_ plan: MnemonicReadingPlan, windowID: UUID?) async -> MnemonicReadingResult? {
        await MnemonicReadingCoordinator.shared.make(plan, windowID: windowID, in: self)
    }

    /// The lists read the library's records again after a reading's source
    /// was written, so its row appears, and an open reading reads its body.
    func reloadArtifactsAfterMnemonicReadingWrite() async {
        if let reloaded = try? await loadScopedArtifacts() {
            artifacts = reloaded
        }
        readerQuestionsRevision &+= 1
    }
}
#endif
