#if os(macOS)
import Foundation
import Observation
import OSLog

// MARK: - A mnemonic reading, open
//
// docs/memory-design.md, "Mnemonic reading". What the reading view shows and
// does, without a window: the reading's body, each source's text read off the
// main actor and set chapter by chapter as its place scrolls into view (never
// the whole book at once), the questions placed in it, where each stands in
// the learner's Memory, and the answers — written by Memory's rules
// (`StorageService.recordMnemonicReadingAnswer`), never into the reading.

@MainActor
@Observable
final class MnemonicReadingModel {
    private static let logger = Logger(subsystem: "com.foreverlm", category: "MnemonicReading")

    let readingID: String
    /// This opening of the reading: one answer per card per sitting, as the
    /// card review counts them.
    let sittingKey: String

    private(set) var reading: MnemonicReading?
    private(set) var loadError: String?
    private(set) var texts: [String: MnemonicReadingSourceText] = [:]
    /// Each source's title as the library has it now.
    private(set) var titles: [String: String] = [:]
    /// Where each answered question stands in Memory, by question id.
    private(set) var memory: [String: MnemonicQuestionMemory] = [:]
    private(set) var rows: [MnemonicReadingRow] = []
    /// Questions whose answer is shown.
    var revealed: Set<String> = []
    /// Answered questions opened again from their one quiet line.
    var unfolded: Set<String> = []
    /// Answers being written.
    private(set) var answering: Set<String> = []
    /// Why an answer could not be written, by question id.
    private(set) var answerErrors: [String: String] = [:]
    /// The question last answered or opened, which Next goes on from.
    var currentQuestionID: String?
    /// Questions a host that does not set the text itself has placed on its
    /// own page (the Reader's PDF layer): their quote is printed there, so a
    /// first answer can anchor the card on it.
    private(set) var placedElsewhere: Set<String> = []

    /// Each source's stored text, kept to place the questions again when the
    /// reading grows; never written anywhere.
    private var storedTexts: [String: String] = [:]
    private var textsInFlight = Set<String>()

    init(readingID: String, sittingToken: String = String(UUID().uuidString.prefix(8)).lowercased()) {
        self.readingID = readingID
        self.sittingKey = "reading-\(readingID)-\(sittingToken)"
    }

    // MARK: Counts

    func counts(now: Date = Date()) -> MnemonicReadingProgress.Counts {
        guard let reading else { return .init(questions: 0, answered: 0, due: 0) }
        return MnemonicReadingProgress.counts(of: reading, memory: memory, now: now)
    }

    /// The questions as the reading shows them, for Next.
    var questionOrder: [String] {
        reading.map { MnemonicReadingRows.questionOrder(of: $0, texts: texts) } ?? []
    }

    /// The next question not answered yet after the current one, going round
    /// to the start; nil when every one is answered.
    func nextUnansweredQuestionID() -> String? {
        MnemonicReadingProgress.nextUnanswered(in: questionOrder, answered: Set(memory.keys), after: currentQuestionID)
    }

    /// The source a question stands in.
    func sourceID(ofQuestion questionID: String) -> String? {
        reading?.question(id: questionID)?.sourceID
    }

    // MARK: Reading

    /// Reads the reading's body and where its questions stand in Memory.
    /// Sources already read are placed again when their questions changed
    /// (a source written since); the others wait to scroll into view.
    func load(storage: StorageService) async {
        do {
            let (_, read) = try await storage.mnemonicReading(readingID)
            let changed = read.sections.filter { section in
                reading?.section(sourceID: section.sourceID)?.questions != section.questions
            }.map(\.sourceID)
            reading = read
            loadError = nil
            var titles: [String: String] = [:]
            for section in read.sections {
                do {
                    if let source = try await storage.loadSourceWithoutContent(section.sourceID) {
                        titles[section.sourceID] = source.title
                    }
                } catch {
                    Self.logger.error("Reading a source's title failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            self.titles = titles
            for sourceID in changed {
                if let text = storedTexts[sourceID], let section = read.section(sourceID: sourceID) {
                    texts[sourceID] = .loaded(await Self.layout(text: text, questions: section.questions))
                }
            }
            rebuildRows()
            await refreshMemory(storage: storage)
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Reads one source's text off the main actor and places its questions
    /// in it, once; what it reads is set chapter by chapter, as each one's
    /// place scrolls into view.
    func loadText(of sourceID: String, storage: StorageService) async {
        guard let section = reading?.section(sourceID: sourceID),
              storedTexts[sourceID] == nil, textsInFlight.insert(sourceID).inserted else { return }
        defer { textsInFlight.remove(sourceID) }
        let state: MnemonicReadingSourceText
        let stored: StudioArticle?
        do {
            stored = try await storage.loadSourceWithoutContent(sourceID)
        } catch {
            Self.logger.error("Reading a source for its reading failed: \(error.localizedDescription, privacy: .public)")
            stored = nil
        }
        if stored == nil {
            state = .unavailable("This source is not in the library.")
        } else {
            let text = (await storage.loadSourceContent(sourceID) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                state = .unavailable("This source has no text yet.")
            } else {
                storedTexts[sourceID] = text
                // The questions as they stand now: the body may have grown
                // while the text was read.
                let questions = reading?.section(sourceID: sourceID)?.questions ?? section.questions
                state = .loaded(await Self.layout(text: text, questions: questions))
            }
        }
        texts[sourceID] = state
        rebuildRows()
    }

    /// The source's text with its questions placed, off the main actor.
    private nonisolated static func layout(text: String, questions: [MnemonicQuestion]) async -> MnemonicReadingLayout {
        await Task.detached(priority: .userInitiated) {
            MnemonicReadingPlacement.layout(text: text, questions: questions)
        }.value
    }

    /// Where every question stands in the learner's Memory, read again.
    func refreshMemory(storage: StorageService) async {
        guard let questions = reading?.questions, !questions.isEmpty else {
            memory = [:]
            return
        }
        do {
            memory = try await storage.mnemonicReadingMemory(for: questions)
        } catch {
            Self.logger.error("Reading the questions' memory failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func rebuildRows() {
        guard let reading else {
            rows = []
            return
        }
        rows = MnemonicReadingRows.rows(of: reading, texts: texts, titles: titles)
    }

    /// A host that shows the source's text itself says which questions its
    /// page carries; `canAnswer` then lets them be answered without the
    /// reading's own layout. The store still refuses a first answer whose
    /// quote the source's stored text does not print.
    func notePlacedElsewhere(_ ids: Set<String>) {
        if placedElsewhere != ids { placedElsewhere = ids }
    }

    // MARK: Answering

    /// Show Answer: the answer and why, then the grade.
    func reveal(_ questionID: String) {
        revealed.insert(questionID)
        currentQuestionID = questionID
    }

    /// A graded question folds to its one quiet line; a click opens it again.
    func toggleUnfolded(_ questionID: String) {
        if unfolded.contains(questionID) {
            unfolded.remove(questionID)
            revealed.remove(questionID)
        } else {
            unfolded.insert(questionID)
            currentQuestionID = questionID
        }
    }

    /// Forgot or Remembered. The first answer keeps the question as a Memory
    /// card with this grade as its first attempt; a later one is written only
    /// while the card is due (`MnemonicReadingAnswerOutcome`). The question
    /// then folds to its quiet line. A write that fails is said on the card.
    @discardableResult
    func answer(_ question: MnemonicQuestion, remembered: Bool, storage: StorageService) async -> MnemonicReadingAnswer? {
        guard answering.insert(question.id).inserted else { return nil }
        defer { answering.remove(question.id) }
        answerErrors[question.id] = nil
        currentQuestionID = question.id
        do {
            let answer = try await storage.recordMnemonicReadingAnswer(question, remembered: remembered, sittingKey: sittingKey)
            memory[question.id] = answer.memory
            revealed.remove(question.id)
            unfolded.remove(question.id)
            return answer
        } catch {
            answerErrors[question.id] = error.localizedDescription
            return nil
        }
    }

    /// Whether a question can be answered here: kept already (a later
    /// grade needs no passage), or its source's text is read and prints its
    /// quote, which its first answer anchors the card on.
    func canAnswer(_ questionID: String) -> Bool {
        if memory[questionID] != nil || placedElsewhere.contains(questionID) { return true }
        guard let sourceID = sourceID(ofQuestion: questionID),
              case .loaded(let layout) = texts[sourceID] else { return false }
        return !layout.unplaced.contains { $0.id == questionID }
    }
}
#endif
