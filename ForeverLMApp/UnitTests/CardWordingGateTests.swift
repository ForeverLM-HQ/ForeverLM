import Foundation
import Testing
@testable import ForeverLM

/// A card stands on its own (docs/memory-design.md, "A card stands on its
/// own"): the gate every model- or assistant-written card face passes before
/// it is saved, and the day close's one repair of the cards kept before it.
/// The gate's model is canned (`CannedCardWording`); the repair runs over a
/// store of its own with its rows and progress held in memory.
@Suite("Memory cards: a card stands on its own")
struct CardWordingGateTests {
    private static let lectureTitle = "Mitochondrial Cell Biology 2"
    private static let pointing = "In this lecture, what structural feature of cardiolipin distinguishes it from most other phospholipids?"
    private static let named = "Which structural feature of cardiolipin distinguishes it from most other phospholipids?"
    private static let back = "Four acyl chains on a glycerol backbone, where most phospholipids have two."

    // MARK: The turns

    @Test("The check reads every card with its source's title, and its reply must answer every card")
    func turns() throws {
        let faces = [
            CardWordingCheck.Face(front: Self.pointing, back: Self.back, sourceTitle: Self.lectureTitle),
            CardWordingCheck.Face(front: "What does complex IV reduce?", back: "Oxygen, to water.", sourceTitle: "Mitochondria"),
        ]
        let message = CardWordingCheck.checkMessage(faces)
        #expect(message.contains("Card 1, from \u{201C}Mitochondrial Cell Biology 2\u{201D}\nQuestion: \(Self.pointing)\nAnswer: \(Self.back)"))
        #expect(message.contains("Card 2, from \u{201C}Mitochondria\u{201D}"))

        let verdicts = try CardWordingCheck.verdicts(
            from: #"{"cards": [{"card": 1, "stands_alone": false, "problem": "asks about this lecture"}, {"card": 2, "stands_alone": true, "problem": null}]}"#,
            count: 2
        )
        #expect(verdicts[1] == .init(standsAlone: false, problem: "asks about this lecture"))
        #expect(verdicts[2] == .init(standsAlone: true, problem: nil))
        // A reply that leaves a card out is no verdict: nothing is taken on a guess.
        #expect(throws: CardWordingCheck.ReplyError.self) {
            try CardWordingCheck.verdicts(from: #"{"cards": [{"card": 1, "stands_alone": true}]}"#, count: 2)
        }

        let kept = CardWordingCheck.rewordMessage([(faces[0], "asks about this lecture")], answersMayChange: false)
        #expect(kept.contains("The answers may not change"))
        #expect(kept.contains("What is wrong: asks about this lecture"))
        let rewordings = try CardWordingCheck.rewordings(
            from: #"{"cards": [{"card": 1, "front": "Which structural feature of cardiolipin distinguishes it?", "back": "Changed."}]}"#,
            count: 1,
            answersMayChange: false
        )
        #expect(rewordings[1] == .init(front: "Which structural feature of cardiolipin distinguishes it?", back: nil), "a kept card's answer never changes")

        for rule in ["\"this lecture\"", "\"the speaker\"", "\"stands_alone\""] {
            #expect(Prompts.cardWordingCheck.contains(rule))
        }
        // A question with several correct answers, whose card holds the source's one, is held back too.
        #expect(Prompts.cardStandsAloneRule.contains("the question has one answer"))
        #expect(Prompts.cardWordingCheck.contains("more than one correct answer"))
        #expect(Prompts.cardWordingRewrite.contains("attribute it"))
        #expect(Prompts.cardVariationJudge.contains("in several ways"))
        #expect(Prompts.cardDrafter.contains(Prompts.cardStandsAloneRule))
        #expect(Prompts.cardVariation.contains(Prompts.cardStandsAloneRule))
        #expect(Prompts.situatedCards.contains(Prompts.cardStandsAloneRule))
        #expect(Prompts.mnemonicReadingWriter.contains("\"this lecture\" without naming it"))
        #expect(AITask.cardWordingCheck.rawValue == "card_wording_check")
        #expect(AITask.cardWordingCheck.isBackgroundWork)
        #expect(AITask.cardWordingCheck.usesBackgroundModelDefault)
        #expect(AITask.advancedTasks.contains(.cardWordingCheck))
    }

    // MARK: The gate

    @Test("A face that stands alone passes in one call; one that points is reworded once with its title and checked again, or fails")
    func screens() async throws {
        let wording = CannedCardWording(pointing: ["this lecture", "the speaker"]) { question in
            question == Self.pointing ? Self.named : nil
        }
        let usage = AIUsageSource(id: "src-lecture", type: "video", title: Self.lectureTitle)
        let fine = try await CardWordingGate.screen(
            [.init(front: Self.named, back: Self.back, sourceTitle: Self.lectureTitle)],
            answersMayChange: true, usage: usage, backend: wording
        )
        #expect(fine == [.passed])
        #expect(wording.checks.count == 1)
        #expect(wording.rewordings.isEmpty)

        let outcomes = try await CardWordingGate.screen([
            .init(front: Self.pointing, back: Self.back, sourceTitle: Self.lectureTitle),
            .init(front: "What does the speaker say cardiolipin binds?", back: "Cytochrome c.", sourceTitle: Self.lectureTitle),
            .init(front: Self.named, back: Self.back, sourceTitle: Self.lectureTitle),
        ], answersMayChange: true, usage: usage, backend: wording)
        #expect(outcomes[0] == .reworded(front: Self.named, back: Self.back))
        guard case .failed(let reason) = outcomes[1] else {
            Issue.record("a rewording that still points is not saved")
            return
        }
        #expect(reason.contains("points at its source"))
        #expect(outcomes[2] == .passed)
        #expect(wording.checks.count == 3, "one check, then one check of the rewordings")
        #expect(wording.rewordings.count == 1)
        #expect(wording.rewordings.last?.contains("from \u{201C}\(Self.lectureTitle)\u{201D}") == true, "the rewording may name the source")

        let down = CannedCardWording(failure: CardWordingGate.Unavailable(message: "No model is set up for Card Wording Check."))
        await #expect(throws: CardWordingGate.Unavailable.self) {
            _ = try await CardWordingGate.screen(
                [.init(front: Self.named, back: Self.back, sourceTitle: Self.lectureTitle)],
                answersMayChange: true, usage: usage, backend: down
            )
        }
    }

    // MARK: The repair

    /// Rows and the repair's progress held in memory.
    private final class Memory: @unchecked Sendable {
        private let lock = NSLock()
        private var rows: [String: MemoryCardDeckState] = [:]
        private var stored: CardWordingRepairProgress?
        private(set) var writes = 0

        var progress: CardWordingRepairProgress? { lock.withLock { stored } }
        func setProgress(_ progress: CardWordingRepairProgress) { lock.withLock { stored = progress } }
        func row(_ deckID: String) -> MemoryCardDeckState { lock.withLock { rows[deckID] ?? MemoryCardDeckState() } }
        func set(_ deckID: String, _ row: MemoryCardDeckState) { lock.withLock { rows[deckID] = row } }

        func write(_ deckID: String, _ changes: [CardWordingRepairWrite], _ now: Date) {
            lock.withLock {
                var row = rows[deckID] ?? MemoryCardDeckState()
                CardWordingRepairPass.apply(changes, to: &row, at: now)
                rows[deckID] = row
                writes += 1
            }
        }
    }

    private static func repair(
        _ storage: StorageService,
        _ backend: CannedCardWording,
        _ memory: Memory,
        spendAllowed: Bool = true
    ) -> CardWordingRepairPass {
        CardWordingRepairPass(
            storage: storage,
            backend: backend,
            spendAllowed: { spendAllowed },
            readProgress: { memory.progress },
            writeProgress: { memory.setProgress($0) },
            readState: { memory.row($0) },
            write: { deckID, writes, now in memory.write(deckID, writes, now) }
        )
    }

    private static let keptAt = Date(timeIntervalSinceReferenceDate: 812_000_000)
    private static let text = "Unlike most phospholipids, cardiolipin carries four acyl chains on a glycerol backbone. It binds cytochrome c."

    /// A store holding the lecture and two cards kept on it, one pointing at
    /// "this lecture" and answered once, one standing alone.
    private static func storageWithCards() async throws -> (StorageService, MemoryItem, MemoryItem, () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CardWordingRepair_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = StorageService(storeRoot: root)
        var source = StudioArticle(url: "https://example.org/lecture-2", title: lectureTitle, sourceType: .article, discoveryOrigin: .manual, id: "src-lecture")
        source.normalizedURL = URLNormalizer.normalize(source.url)
        source.content = text
        source.state = .ready
        try await storage.saveSource(source)
        let deckID = MemoryCard.draftDeckID(sourceID: "src-lecture")
        let pointingCard = MemoryCard(cardID: "card-cardiolipin", front: pointing, back: back, origin: .drafted, deckID: deckID)
        let first = try await storage.keepMemoryCard(pointingCard, sourceID: "src-lecture", quote: "cardiolipin carries four acyl chains", at: keptAt)
        _ = try await storage.recordMemoryAttempt(MemoryAttempt(
            id: "answer-1", memoryItemID: first.id, prompt: pointing, learnerAnswer: "Four chains.",
            score: 1, scheduleRating: .good, gradeState: .graded, attemptedAt: keptAt.addingTimeInterval(86_400)
        ))
        let standing = MemoryCard(cardID: "card-cytochrome", front: "Which protein does cardiolipin bind?", back: "Cytochrome c.", origin: .drafted, deckID: deckID)
        let second = try await storage.keepMemoryCard(standing, sourceID: "src-lecture", quote: "It binds cytochrome c", at: keptAt.addingTimeInterval(60))
        return (storage, first, second, { try? FileManager.default.removeItem(at: root) })
    }

    @Test("The repair rewords the cardiolipin card's question once, keeping its id, its item, its schedule and its answers, and never runs again")
    func repairsOnce() async throws {
        let (storage, pointingItem, standingItem, cleanup) = try await Self.storageWithCards()
        defer { cleanup() }
        let deckID = MemoryCard.draftDeckID(sourceID: "src-lecture")
        let memory = Memory()
        // The card had rewordings made from its old question.
        memory.set(deckID, MemoryCardDeckState(cards: ["card-cardiolipin": MemoryCardState(
            status: .kept, memoryItemID: pointingItem.id,
            variants: ["In this lecture, which feature of cardiolipin is unusual?"],
            variedAt: Self.keptAt, updatedAt: Self.keptAt
        )]))
        let wording = CannedCardWording(pointing: ["this lecture"]) { $0 == Self.pointing ? Self.named : nil }
        let attemptsBefore = try await storage.loadMemoryAttempts(memoryItemID: pointingItem.id)
        let now = Self.keptAt.addingTimeInterval(10 * 86_400)

        let report = await Self.repair(storage, wording, memory).run(now: now)
        #expect(report.checked == 2)
        #expect(report.reworded == 1)
        #expect(report.leftAsTheyAre == 0)
        #expect(report.finished)
        #expect(report.failures.isEmpty)
        #expect(wording.rewordings.first?.contains("The answers may not change") == true, "a kept card's answer is its identity")

        let state = try #require(memory.row(deckID).cards["card-cardiolipin"])
        #expect(state.editedFront == Self.named)
        #expect(state.variants.isEmpty && state.variedAt == nil, "rewordings of the old question go, to be made again")
        #expect(state.status == .kept)
        #expect(memory.row(deckID).cards["card-cytochrome"] == nil, "a card that stands alone is not touched")

        // Its identity, schedule and history are as they were.
        #expect(try await storage.loadMemoryItem(pointingItem.id)?.status == .active)
        #expect(try await storage.loadMemoryAttempts(memoryItemID: pointingItem.id).map(\.id) == attemptsBefore.map(\.id))
        #expect(try await storage.loadMemoryItem(standingItem.id)?.status == .active)

        // The review asks it by its subject now.
        let face = try #require(MemoryCard.face(of: pointingItem, attempts: attemptsBefore))
        #expect(face.cardID == "card-cardiolipin")
        #expect(face.wording(state: state) == Self.named)

        // Done: the next close sends nothing.
        let checks = wording.checks.count
        let again = await Self.repair(storage, wording, memory).run(now: now.addingTimeInterval(86_400))
        #expect(again.finished)
        #expect(again.checked == 0)
        #expect(wording.checks.count == checks)
        #expect(memory.progress?.finishedAt == now)
    }

    @Test("The repair records which cards are its own before it spends, waits at the daily limit, and resumes where it stopped")
    func repairResumes() async throws {
        let (storage, pointingItem, _, cleanup) = try await Self.storageWithCards()
        defer { cleanup() }
        let memory = Memory()
        let wording = CannedCardWording(pointing: ["this lecture"]) { $0 == Self.pointing ? Self.named : nil }
        let firstClose = Self.keptAt.addingTimeInterval(10 * 86_400)

        let capped = await Self.repair(storage, wording, memory, spendAllowed: false).run(now: firstClose)
        #expect(capped.waiting == 2)
        #expect(!capped.finished)
        #expect(wording.checks.isEmpty, "nothing is sent past the limit")
        #expect(memory.progress?.cutoff == firstClose, "the cards it covers are recorded first")
        #expect(memory.progress?.cursorItemID == nil)

        // A check that fails leaves the cursor where it was.
        let down = CannedCardWording(failure: CardWordingGate.Unavailable(message: "No model is set up for Card Wording Check."))
        let failed = await Self.repair(storage, down, memory).run(now: firstClose.addingTimeInterval(86_400))
        #expect(failed.failures.first?.contains("could not be checked") == true)
        #expect(!failed.finished)
        #expect(memory.progress?.cursorItemID == nil)

        // A card kept after the cutoff passed the gate when it was written: not the repair's.
        let later = MemoryCard(
            cardID: "card-later", front: "In this lecture, what does cardiolipin bind?", back: "Cytochrome c.",
            origin: .drafted, deckID: MemoryCard.draftDeckID(sourceID: "src-lecture")
        )
        _ = try await storage.keepMemoryCard(later, sourceID: "src-lecture", quote: "It binds cytochrome c", at: firstClose.addingTimeInterval(3_600))

        let resumed = await Self.repair(storage, wording, memory).run(now: firstClose.addingTimeInterval(2 * 86_400))
        #expect(resumed.finished)
        #expect(resumed.checked == 2)
        #expect(resumed.reworded == 1)
        #expect(memory.progress?.cursorItemID != nil)
        let deckID = MemoryCard.draftDeckID(sourceID: "src-lecture")
        #expect(memory.row(deckID).cards["card-cardiolipin"]?.editedFront == Self.named)
        #expect(memory.row(deckID).cards["card-later"] == nil)
        #expect(try await storage.loadMemoryItem(pointingItem.id)?.status == .active)
    }

    @Test("The cursor covers the cards kept before the cutoff, after the last one checked")
    func cursor() {
        let cutoff = Self.keptAt.addingTimeInterval(100)
        var progress = CardWordingRepairProgress(cutoff: cutoff)
        #expect(progress.covers(createdAt: Self.keptAt, itemID: "a"))
        #expect(!progress.covers(createdAt: cutoff, itemID: "a"), "kept at the cutoff passed the gate")
        progress.cursorCreatedAt = Self.keptAt
        progress.cursorItemID = "b"
        #expect(!progress.covers(createdAt: Self.keptAt, itemID: "a"))
        #expect(!progress.covers(createdAt: Self.keptAt, itemID: "b"))
        #expect(progress.covers(createdAt: Self.keptAt, itemID: "c"))
        #expect(progress.covers(createdAt: Self.keptAt.addingTimeInterval(1), itemID: "a"))
    }
}
