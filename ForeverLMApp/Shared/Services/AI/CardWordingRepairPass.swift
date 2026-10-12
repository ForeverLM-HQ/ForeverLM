import Foundation
import OSLog

/// What one run of the wording repair did, for the day close's receipt.
struct CardWordingRepairReport: Equatable, Sendable {
    /// Kept cards checked this run.
    var checked = 0
    /// Of those, the cards whose question was reworded to name what it is
    /// about.
    var reworded = 0
    /// Of those, the cards that still point at their source after one
    /// rewording, or whose answer does (a kept card's answer is never
    /// changed): left as they are, for the learner to edit.
    var leftAsTheyAre = 0
    /// Cards still to check: the daily background limit stopped the run.
    var waiting = 0
    /// The repair has checked every card it covers, and never runs again.
    var finished = false
    var failures: [String] = []
}

/// The repair's bookkeeping, kept on this Mac: which cards it covers and how
/// far it has come. Written before anything is spent (the enqueue), after
/// every batch (resumable), and once more when it is done (never repeats).
struct CardWordingRepairProgress: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    /// The cards kept before this instant are the repair's: every card since
    /// passed the gate when it was written.
    let cutoff: Date
    /// The last card checked, in the order the repair reads them (when it
    /// was kept, then its id).
    var cursorCreatedAt: Date?
    var cursorItemID: String?
    /// When the last card was checked; nil while cards remain.
    var finishedAt: Date?

    init(cutoff: Date) {
        version = Self.currentVersion
        self.cutoff = cutoff
    }

    /// Whether a card kept at `createdAt` under `itemID` is still to check:
    /// kept before the cutoff, and after the cursor.
    func covers(createdAt: Date, itemID: String) -> Bool {
        guard createdAt < cutoff else { return false }
        guard let cursorCreatedAt, let cursorItemID else { return true }
        if createdAt != cursorCreatedAt { return createdAt > cursorCreatedAt }
        return itemID > cursorItemID
    }
}

/// A kept card's new question as its state row keeps it.
struct CardWordingRepairWrite: Equatable, Sendable {
    let cardID: String
    let itemID: String
    let front: String
    /// An item from before cards, whose row still says draft until the
    /// learner goes through it in To Check.
    let isFromBeforeCards: Bool
}

/// Brings the cards kept before the wording gate up to its rule, once
/// (docs/memory-design.md, "A card stands on its own"). Not a migration: a
/// migration calls no model. At the first day close of a build that has it,
/// the repair records which cards it covers — those kept before that moment —
/// and then drains them in bounded batches at the day close, background work
/// that stops at the daily limit like rewording does, and resumes at the next
/// close from where it stopped. Each batch goes through the same gate as a
/// new card (`CardWordingGate`), asking only for a new question: a kept
/// card's answer is its identity. A question reworded is written as the
/// learner's own rewording would be (`MemoryCardState.editedFront`), so the
/// card keeps its id, its item, its schedule and its answers; its
/// rewordings, made from the old question, are cleared so the variation pass
/// rewords it again from the new one. A card the rewording does not fix is
/// left as it is. Cards on sources kept from AI are never sent.
struct CardWordingRepairPass: Sendable {
    /// The most cards one check reads.
    static let batchSize = 20
    /// Where this Mac keeps the repair's progress. Local: each Mac checks the
    /// cards once, and a card another Mac reworded passes here.
    static let progressKey = "memory.cardWordingRepair.v1"

    let storage: StorageService
    let backend: any CardWordingBackend
    /// Whether background AI may spend now (`StudioViewModel.backgroundAISpendAllowed`).
    let spendAllowed: @Sendable () async -> Bool
    let readProgress: @Sendable () -> CardWordingRepairProgress?
    let writeProgress: @Sendable (CardWordingRepairProgress) -> Void
    /// One deck's card states as stored (`MemoryCardStateStore.load`).
    let readState: @Sendable (_ deckID: String) -> MemoryCardDeckState
    /// Writes a deck's new questions into its row.
    let write: @Sendable (_ deckID: String, _ writes: [CardWordingRepairWrite], _ at: Date) async -> Void

    private static let logger = Logger(subsystem: "com.foreverlm", category: "CardWordingRepair")

    /// The learner's card states on this Mac, and the progress in this Mac's
    /// standard defaults.
    static func live(
        storage: StorageService,
        backend: any CardWordingBackend = CardWordingGate.backend(),
        spendAllowed: @escaping @Sendable () async -> Bool
    ) -> CardWordingRepairPass {
        CardWordingRepairPass(
            storage: storage,
            backend: backend,
            spendAllowed: spendAllowed,
            readProgress: {
                UserDefaults.standard.data(forKey: progressKey)
                    .flatMap { try? JSONDecoder().decode(CardWordingRepairProgress.self, from: $0) }
            },
            writeProgress: { progress in
                if let data = try? JSONEncoder().encode(progress) {
                    UserDefaults.standard.set(data, forKey: progressKey)
                }
            },
            readState: { MemoryCardStateStore.load(deckID: $0) },
            write: { deckID, writes, now in
                await MainActor.run {
                    _ = MemoryCardStateStore.update(deckID: deckID) { row in
                        apply(writes, to: &row, at: now)
                    }
                }
                await MemoryCardStateStore.settled()
            }
        )
    }

    /// Each card's new question in its row, as the learner's rewording: its
    /// rewordings from the old question are cleared, and made again from the
    /// new one at a later close. Nothing else in the row changes.
    static func apply(_ writes: [CardWordingRepairWrite], to row: inout MemoryCardDeckState, at now: Date) {
        for write in writes {
            var state = row.cards[write.cardID] ?? MemoryCardState(
                status: write.isFromBeforeCards ? .draft : .kept,
                memoryItemID: write.itemID,
                updatedAt: now
            )
            if state.memoryItemID == nil { state.memoryItemID = write.itemID }
            state.editedFront = write.front
            if !state.variants.isEmpty {
                state.variants = []
                state.variedAt = nil
            }
            state.updatedAt = now
            row.cards[write.cardID] = state
        }
    }

    func run(now: Date = Date()) async -> CardWordingRepairReport {
        var report = CardWordingRepairReport()
        var progress: CardWordingRepairProgress
        if let stored = readProgress(), stored.version == CardWordingRepairProgress.currentVersion {
            progress = stored
        } else {
            // The enqueue: which cards are the repair's, recorded before
            // anything is spent.
            progress = CardWordingRepairProgress(cutoff: now)
            writeProgress(progress)
        }
        guard progress.finishedAt == nil else {
            report.finished = true
            return report
        }

        let reviewable: (items: [MemoryItem], attempts: [MemoryAttempt])
        let keptFromAI: Set<String>
        do {
            reviewable = try await storage.memoryCardVariationItems()
            keptFromAI = try await storage.knowledgeSearchExcludedSourceIDs(includeArchived: true)
        } catch {
            report.failures.append("Kept cards could not be read to check their wording: \(error.localizedDescription)")
            return report
        }
        let attemptsByItemID = Dictionary(grouping: reviewable.attempts, by: \.memoryItemID)
        let due = reviewable.items
            .filter { progress.covers(createdAt: $0.createdAt, itemID: $0.id) }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id < $1.id
            }

        var titles: [String: String] = [:]
        var rows: [String: MemoryCardDeckState] = [:]
        var remaining = due.count
        for start in stride(from: 0, to: due.count, by: Self.batchSize) {
            let batch = Array(due[start..<min(start + Self.batchSize, due.count)])
            // A card on a source kept from AI (the knowledge boundary) is
            // never sent to a model, and a memory item with no face is no
            // card: both are passed over.
            var cards: [(listing: MemoryCardListing, deckID: String?, wording: String)] = []
            for item in batch {
                guard !item.sources.contains(where: { keptFromAI.contains($0.sourceID) }),
                      let listing = MemoryCardListing(item: item, attempts: attemptsByItemID[item.id] ?? []) else { continue }
                let deckID = MemoryCardEditWriter.stateDeckID(listing)
                if let deckID, rows[deckID] == nil { rows[deckID] = readState(deckID) }
                let state = deckID.flatMap { rows[$0]?.cards[listing.face.cardID] }
                cards.append((listing, deckID, listing.face.wording(state: state)))
            }
            if !cards.isEmpty {
                guard await spendAllowed() else {
                    report.waiting = remaining
                    Self.logger.notice("Card wording repair paused at the background cap with \(remaining) card(s) waiting")
                    return report
                }
                var faces: [CardWordingCheck.Face] = []
                for card in cards {
                    faces.append(CardWordingCheck.Face(
                        front: card.wording,
                        back: card.listing.face.back,
                        sourceTitle: await title(of: card.listing.sourceIDs.first, cache: &titles)
                    ))
                }
                let outcomes: [CardWordingCheck.Outcome]
                do {
                    outcomes = try await CardWordingGate.screen(
                        faces,
                        answersMayChange: false,
                        usage: AIUsageSource(
                            id: cards[0].listing.sourceIDs.first ?? cards[0].listing.itemID,
                            type: "memory_card",
                            title: faces[0].sourceTitle
                        ),
                        backend: backend
                    )
                } catch {
                    if error is CancellationError || Task.isCancelled { return report }
                    // The cursor stays: the batch is checked again next time.
                    report.failures.append("The wording of kept cards could not be checked: \(error.localizedDescription)")
                    return report
                }
                var deckOrder: [String] = []
                var byDeck: [String: [CardWordingRepairWrite]] = [:]
                for (card, outcome) in zip(cards, outcomes) {
                    report.checked += 1
                    switch outcome {
                    case .passed:
                        break
                    case .reworded(let front, _):
                        guard let deckID = card.deckID else {
                            report.leftAsTheyAre += 1
                            continue
                        }
                        if byDeck[deckID] == nil { deckOrder.append(deckID) }
                        byDeck[deckID, default: []].append(CardWordingRepairWrite(
                            cardID: card.listing.face.cardID,
                            itemID: card.listing.itemID,
                            front: front,
                            isFromBeforeCards: card.listing.face.origin == .legacy
                        ))
                        report.reworded += 1
                    case .failed:
                        report.leftAsTheyAre += 1
                    }
                }
                for deckID in deckOrder {
                    let writes = byDeck[deckID] ?? []
                    await write(deckID, writes, now)
                    if var row = rows[deckID] {
                        Self.apply(writes, to: &row, at: now)
                        rows[deckID] = row
                    }
                }
            }
            if let last = batch.last {
                progress.cursorCreatedAt = last.createdAt
                progress.cursorItemID = last.id
                writeProgress(progress)
            }
            remaining -= batch.count
        }
        progress.finishedAt = now
        writeProgress(progress)
        report.finished = true
        Self.logger.notice("Card wording repair checked \(report.checked) card(s), reworded \(report.reworded), left \(report.leftAsTheyAre) as they are")
        return report
    }

    /// A source's title for the check, read once a run.
    private func title(of sourceID: String?, cache: inout [String: String]) async -> String {
        guard let sourceID else { return "an unnamed source" }
        if let known = cache[sourceID] { return known }
        let title = (try? await storage.loadSourceWithoutContent(sourceID))?.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let named = (title?.isEmpty == false ? title : nil) ?? "an unnamed source"
        cache[sourceID] = named
        return named
    }
}
