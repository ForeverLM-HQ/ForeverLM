#if os(macOS)
import Foundation
import Observation
import os

// MARK: - A source's reading questions, in the Reader
//
// docs/memory-design.md, "Mnemonic reading on the paper's PDF". The Reader's
// PDF shows the questions of every mnemonic reading that is grounded on the
// source it displays, at the passages they follow, and answers them by the
// reading's own rules (`MnemonicReadingModel`). This is the store the PDF
// layer and the Reader's chip read: which readings, which questions, where
// each stands in Memory, and the order the page puts them in for Next.
// Nothing here writes a reading; an answer writes Memory only.

/// One question the PDF layer draws a marker for.
struct ReaderQuestionMarker: Equatable, Sendable {
    enum Standing: Equatable, Sendable {
        /// Not answered: kept nowhere yet.
        case open
        /// Answered, and not asked again yet.
        case kept
        /// Answered, and the card review asks it now.
        case due
    }

    let questionID: String
    let sourceID: String
    let quote: String
    let standing: Standing
}

@MainActor
@Observable
final class ReaderQuestionsModel {
    private static let logger = Logger(subsystem: "com.foreverlm", category: "ReaderQuestions")
    /// A question and the reading whose model answers it.
    struct Entry: Equatable {
        let question: MnemonicQuestion
        let readingID: String
    }

    /// Whether the markers are drawn. A convenience for reading the page
    /// bare; it changes nothing the learner has answered.
    var isVisible = true
    /// The question last opened or answered, which Next goes on from.
    private(set) var currentQuestionID: String?
    /// The sources the entries were read for, in the order asked.
    private(set) var loadedSourceIDs: [String] = []
    private(set) var entries: [Entry] = []
    /// One model per reading, kept between loads so a question's sitting and
    /// what is revealed survive a reading growing.
    private(set) var models: [String: MnemonicReadingModel] = [:]
    /// The questions the PDF carries, as the page orders them, top to bottom.
    private(set) var pageOrder: [String] = []
    /// Questions whose quote the PDF does print (a first answer anchors its
    /// card on the quote, which the source's text must print too).
    private(set) var placedIDs: Set<String> = []

    /// The sources the last load was asked for; set before the first
    /// suspension so one load runs at a time per set.
    @ObservationIgnored private var requested: [String]?
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var reloadWanted = false

    /// Created in the PDF coordinator's stored-property initialiser, which is
    /// not on any actor; everything it does afterwards is.
    nonisolated init() {}

    // MARK: Loading

    /// Whether `sourceIDs` has to be read (new sources, or `invalidate()`).
    func needsLoad(for sourceIDs: [String]) -> Bool {
        requested != sourceIDs
    }

    /// The readings changed under the Reader (a source's questions landed, a
    /// reading was removed): read them again the next time the PDF asks.
    func invalidate() {
        requested = nil
        if loading { reloadWanted = true }
    }

    /// Reads the readings grounded on `sourceIDs` and where their questions
    /// stand in Memory. Cheap to call again; it does nothing while the same
    /// sources are already read.
    func load(sourceIDs: [String], storage: StorageService) async {
        guard needsLoad(for: sourceIDs), !loading else { return }
        requested = sourceIDs
        loading = true
        reloadWanted = false
        defer { loading = false }

        var readingIDs: [String] = []
        // The oldest reading is read first, so a question two readings hold
        // is drawn once, from the first one made.
        let linked: [ArtifactRecord]
        do {
            linked = try await storage.mnemonicReadings(groundedOn: sourceIDs)
        } catch {
            Self.logger.error("Reading the mnemonic readings failed: \(error.localizedDescription, privacy: .public)")
            linked = []
        }
        for artifact in linked {
            readingIDs.append(artifact.id)
            let model = models[artifact.id] ?? MnemonicReadingModel(readingID: artifact.id)
            models[artifact.id] = model
            await model.load(storage: storage)
        }
        for stale in Array(models.keys) where !readingIDs.contains(stale) { models[stale] = nil }

        let wanted = Set(sourceIDs)
        var taken = Set<String>()
        var rebuilt: [Entry] = []
        for readingID in readingIDs {
            guard let reading = models[readingID]?.reading else { continue }
            for section in reading.sections where wanted.contains(section.sourceID) {
                for question in section.questions where taken.insert(question.id).inserted {
                    rebuilt.append(Entry(question: question, readingID: readingID))
                }
            }
        }
        loadedSourceIDs = sourceIDs
        entries = rebuilt
        for model in models.values { model.notePlacedElsewhere(placedIDs) }
        if reloadWanted { requested = nil }
    }

    /// Where every question stands in Memory, read again (a card answered in
    /// the review, a sync).
    func refreshMemory(storage: StorageService) async {
        for model in models.values { await model.refreshMemory(storage: storage) }
    }

    // MARK: What the layer draws

    /// The markers to draw, in the order the reading holds them. Reads the
    /// models' Memory, so a view that calls it in its update is redrawn when
    /// an answer lands.
    func markers(now: Date = Date()) -> [ReaderQuestionMarker] {
        entries.map { entry in
            let memory = models[entry.readingID]?.memory[entry.question.id]
            let standing: ReaderQuestionMarker.Standing
            if let memory {
                standing = memory.isDue(at: now) ? .due : .kept
            } else {
                standing = .open
            }
            return ReaderQuestionMarker(
                questionID: entry.question.id,
                sourceID: entry.question.sourceID,
                quote: entry.question.quote,
                standing: standing
            )
        }
    }

    func entry(for questionID: String) -> Entry? {
        entries.first { $0.question.id == questionID }
    }

    func model(for questionID: String) -> MnemonicReadingModel? {
        entry(for: questionID).flatMap { models[$0.readingID] }
    }

    /// How the sources' questions stand, for the chip: all of them, answered,
    /// and answered ones due now.
    func counts(now: Date = Date()) -> MnemonicReadingProgress.Counts {
        var answered = 0
        var due = 0
        for entry in entries {
            guard let memory = models[entry.readingID]?.memory[entry.question.id] else { continue }
            answered += 1
            if memory.isDue(at: now) { due += 1 }
        }
        return .init(questions: entries.count, answered: answered, due: due)
    }

    var hasQuestions: Bool { !entries.isEmpty }

    // MARK: The page

    /// The layer reports where the PDF carries each question's quote, top to
    /// bottom. A question the PDF does not print is not on the page, so Next
    /// does not go to it.
    func notePlacement(order placed: [String]) {
        let placedSet = Set(placed)
        if placed != pageOrder { pageOrder = placed }
        if placedSet != placedIDs {
            placedIDs = placedSet
            for model in models.values { model.notePlacedElsewhere(placedSet) }
        }
    }

    func noteOpened(_ questionID: String) {
        currentQuestionID = questionID
        model(for: questionID)?.currentQuestionID = questionID
    }

    /// The next question not answered yet after the current one, going round
    /// to the start; nil when every one is answered.
    func nextUnansweredQuestionID() -> String? {
        var answered = Set<String>()
        for entry in entries where models[entry.readingID]?.memory[entry.question.id] != nil {
            answered.insert(entry.question.id)
        }
        return MnemonicReadingProgress.nextUnanswered(in: pageOrder, answered: answered, after: currentQuestionID)
    }
}
#endif
