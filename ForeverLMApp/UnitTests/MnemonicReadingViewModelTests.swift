import Foundation
import Testing
@testable import ForeverLM

// The reading view's logic without a window (docs/memory-design.md, "Mnemonic
// reading"): the rows a reading draws, the questions' order for Next, and the
// model over a store of its own — each source's text read as it scrolls into
// view, answers kept in Memory and the reading's state read back from there.

private let firstChapter = """
# The Characters of the Story

System 1 operates automatically and quickly, with little or no effort.
System 2 allocates attention to the effortful mental activities that demand it.
"""

private let secondChapter = """
Self-control and deliberate thought apparently draw on the same limited budget of effort.
"""

private func question(_ source: String, _ quote: String, _ text: String) -> MnemonicQuestion {
    MnemonicQuestion.mint(sourceID: source, quote: quote, question: text, answer: "An answer.")
}

private let systemOne = question("c1", "System 1 operates automatically and quickly", "Which system operates automatically?")
private let systemTwo = question("c1", "System 2 allocates attention", "Which system allocates attention?")
private let refetched = question("c1", "a sentence the text no longer prints", "What was lost?")
private let budget = question("c2", "the same limited budget of effort", "What do self-control and thought draw on?")

private func reading(secondWritten: Bool = true) -> MnemonicReading {
    MnemonicReading(title: "Thinking, Fast and Slow with questions", sections: [
        .init(sourceID: "c1", title: "The Characters of the Story", isWritten: true, questions: [systemTwo, systemOne, refetched]),
        .init(sourceID: "c2", title: "The Lazy Controller", isWritten: secondWritten, questions: secondWritten ? [budget] : []),
    ])
}

private func article(_ id: String, title: String, text: String) -> StudioArticle {
    var article = StudioArticle(url: "https://example.com/book/\(id)", title: title, sourceType: .article, discoveryOrigin: .manual, id: id)
    article.normalizedURL = URLNormalizer.normalize(article.url)
    article.content = text
    article.wordCount = text.split(whereSeparator: \.isWhitespace).count
    article.state = .ready
    return article
}

@Suite("Mnemonic reading: the view's logic")
struct MnemonicReadingViewModelTests {
    @Test("A reading draws each source under its title: its text a block at a time with each question after its block, the unplaced at its end, and a loading row until it is read")
    func rows() {
        let layout = MnemonicReadingPlacement.layout(text: firstChapter, questions: reading().sections[0].questions)
        let rows = MnemonicReadingRows.rows(
            of: reading(secondWritten: false),
            texts: ["c1": .loaded(layout)],
            titles: ["c1": "Chapter One"]
        )
        #expect(rows.map(\.id) == [
            "heading:c1",
            "block:c1:0",
            "block:c1:1",
            MnemonicReadingRow.questionRowID(systemOne.id),
            "block:c1:2",
            MnemonicReadingRow.questionRowID(systemTwo.id),
            MnemonicReadingRow.questionRowID(refetched.id),
            "heading:c2",
            "pending:c2",
            "loading:c2",
        ])
        #expect(rows.first == .heading(sourceID: "c1", title: "Chapter One"), "the library's title over the one the body keeps")
        #expect(rows[6] == .question(refetched, isUnplaced: true))
        #expect(rows[3] == .question(systemOne, isUnplaced: false))

        let unavailable = MnemonicReadingRows.rows(of: reading(), texts: ["c1": .unavailable("This source is not in the library.")])
        #expect(unavailable.prefix(5).map(\.id) == [
            "heading:c1",
            "unavailable:c1",
            MnemonicReadingRow.questionRowID(systemTwo.id),
            MnemonicReadingRow.questionRowID(systemOne.id),
            MnemonicReadingRow.questionRowID(refetched.id),
        ])
    }

    @Test("Next follows the questions as the reading shows them: a read source's as its text places them, one not read yet in the body's order")
    func questionOrder() {
        let layout = MnemonicReadingPlacement.layout(text: firstChapter, questions: reading().sections[0].questions)
        #expect(MnemonicReadingRows.questionOrder(of: reading(), texts: ["c1": .loaded(layout)])
            == [systemOne.id, systemTwo.id, refetched.id, budget.id])
        #expect(MnemonicReadingRows.questionOrder(of: reading(), texts: [:])
            == [systemTwo.id, systemOne.id, refetched.id, budget.id])
    }

    @Test("Opened, the reading reads its body and waits to read each source until it scrolls into view; answering keeps the card, folds it and moves Next on")
    @MainActor
    func modelOverAStore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MnemonicReadingView_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        try await storage.saveSource(article("c1", title: "The Characters of the Story", text: firstChapter))
        try await storage.saveSource(article("c2", title: "The Lazy Controller", text: secondChapter))
        let skeleton = MnemonicReadingSkeleton(
            title: "Thinking, Fast and Slow with questions",
            notebookID: nil,
            sections: [("c1", "The Characters of the Story"), ("c2", "The Lazy Controller")]
        )
        _ = try await storage.saveMnemonicReadingSection(
            readingID: "r1", sourceID: "c1", sourceTitle: "The Characters of the Story",
            questions: [systemOne, systemTwo], creatingWith: skeleton
        )

        let model = MnemonicReadingModel(readingID: "r1", sittingToken: "test")
        #expect(model.sittingKey == "reading-r1-test")
        await model.load(storage: storage)
        #expect(model.reading?.pendingSourceIDs == ["c2"])
        #expect(model.rows.map(\.id) == ["heading:c1", "loading:c1", "heading:c2", "pending:c2", "loading:c2"])
        #expect(model.counts() == .init(questions: 2, answered: 0, due: 0))
        #expect(!model.canAnswer(systemOne.id), "its source's text is not read yet")

        await model.loadText(of: "c1", storage: storage)
        guard case .loaded(let layout) = model.texts["c1"] else {
            Issue.record("the chapter's text was not read")
            return
        }
        #expect(layout.unplaced.isEmpty)
        #expect(model.rows.contains { $0.id == MnemonicReadingRow.questionRowID(systemOne.id) })
        #expect(model.texts["c2"] == nil, "the other chapter waits until it scrolls into view")
        #expect(model.canAnswer(systemOne.id))
        #expect(model.nextUnansweredQuestionID() == systemOne.id)

        model.reveal(systemOne.id)
        #expect(model.revealed == [systemOne.id])
        let answer = try #require(await model.answer(systemOne, remembered: true, storage: storage))
        #expect(answer.outcome == .kept)
        #expect(model.memory[systemOne.id]?.lastRemembered == true)
        #expect(model.revealed.isEmpty, "a graded question folds to its line")
        #expect(model.counts() == .init(questions: 2, answered: 1, due: 0))
        #expect(model.nextUnansweredQuestionID() == systemTwo.id)
        #expect(model.canAnswer(systemOne.id), "a kept card can be graded again by Memory's rules")

        // Opened again, the reading reads what was answered from Memory.
        let reopened = MnemonicReadingModel(readingID: "r1")
        await reopened.load(storage: storage)
        #expect(Set(reopened.memory.keys) == [systemOne.id])
        #expect(reopened.sittingKey != model.sittingKey)

        // A source written since is placed again in the text already read.
        _ = try await storage.saveMnemonicReadingSection(
            readingID: "r1", sourceID: "c2", sourceTitle: "The Lazy Controller",
            questions: [budget], creatingWith: nil
        )
        await model.load(storage: storage)
        #expect(model.reading?.pendingSourceIDs.isEmpty == true)
        #expect(!model.rows.contains { $0.id == "pending:c2" })
        await model.loadText(of: "c2", storage: storage)
        #expect(model.rows.last?.id == MnemonicReadingRow.questionRowID(budget.id))
    }

    @Test("A source that is gone says so in its place, and its questions cannot be kept until it is back")
    @MainActor
    func missingSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MnemonicReadingView_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        try await storage.saveSource(article("c1", title: "The Characters of the Story", text: firstChapter))
        let skeleton = MnemonicReadingSkeleton(title: "R", notebookID: nil, sections: [("c1", "One")])
        _ = try await storage.saveMnemonicReadingSection(
            readingID: "r2", sourceID: "c1", sourceTitle: "One", questions: [systemOne], creatingWith: skeleton
        )
        try await storage.deleteSource("c1")
        let model = MnemonicReadingModel(readingID: "r2")
        await model.load(storage: storage)
        await model.loadText(of: "c1", storage: storage)
        #expect(model.texts["c1"] == .unavailable("This source is not in the library."))
        #expect(model.rows.map(\.id) == ["heading:c1", "unavailable:c1", MnemonicReadingRow.questionRowID(systemOne.id)])
        #expect(!model.canAnswer(systemOne.id))
    }
}
