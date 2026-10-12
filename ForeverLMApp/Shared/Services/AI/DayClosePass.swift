import Foundation
import OSLog

/// What one day close did, for the receipt in Settings and the `close_day`
/// tool's answer.
struct DayCloseReport: Equatable, Sendable {
    /// Chats folded into understanding documents this run.
    var consolidatedChats = 0
    /// Understanding documents rewritten this run.
    var updatedUnderstandingDocuments = 0
    /// Sources whose ideas were extracted or confirmed this run.
    var warmedSources = 0
    /// Cards drafted in the background this run (`AutomaticCardDraftingPass`),
    /// the sources they came from, and the candidates the day's limit left
    /// for another day.
    var draftedCards = 0
    var draftedSources = 0
    var draftsWaiting = 0
    /// Cards reworded this run (`CardVariationPass`), and of those the ones
    /// with a rewording in their rotation now.
    var rewordedCards = 0
    var variedCards = 0
    /// Kept cards whose question the wording repair reworded this run to
    /// name what it is about (`CardWordingRepairPass`).
    var standaloneRewordedCards = 0
    /// Working notes written or changed this run (`WorkingNoteExtractionPass`).
    var workingNotesWritten = 0
    /// What was left for the next run, not failed: idea extraction or
    /// rewording stopped at the daily background AI limit.
    var notes: [String] = []
    /// What could not be done, in the words the tutor would use. A chat that
    /// failed stays unconsolidated and is found again by the next run.
    var failures: [String] = []
    /// Everything before this instant is now consolidated.
    var watermark: Date?

    var isEmpty: Bool {
        consolidatedChats == 0 && updatedUnderstandingDocuments == 0 && warmedSources == 0
            && draftedCards == 0 && rewordedCards == 0 && workingNotesWritten == 0
            && standaloneRewordedCards == 0
    }
}

/// Folds the day's activity into what the tutor knows, so the next review is
/// planned from consolidated prose rather than from raw rows at seven in the
/// morning.
///
/// Watermark-driven and idempotent (docs/memory-design.md, "The day close"):
/// every run reads what happened since the last one — whichever trigger ran
/// it, the shutdown, the evening hour, or the morning's own preparation — and
/// a run that finds nothing new costs nothing. Three things it does:
///
/// 1. **Chats become understanding.** Every chat the learner wrote in since
///    the watermark — the day's memory review, a review, an ordinary
///    conversation about a source — goes through `closeCohortSession`, the
///    closer that was written for the end of a review and never called: the
///    understanding document of each source the chat is evidence about is
///    rewritten, and the closer's three-line summary lands on the session
///    record. A chat that goes on tomorrow is folded in again from where this
///    run stopped (`chat_consolidations.through_sequence`).
/// 2. **Reading gets its ideas.** A source taken in far enough to be reviewed
///    has its ideas extracted now, so the morning's planner does not pay
///    that latency; a source whose ideas already match its text costs nothing.
/// 3. **Cards are drafted from what was finished.** The candidates of the
///    last ten days the day's limit has room for (`AutomaticCardDraftingPass`;
///    docs/memory-design.md, "Drafting in the background") — read from the
///    cohort's window, never from this watermark, so a source the limit
///    leaves out is drafted another day.
/// 4. **Cards kept before the wording gate stand on their own.** Until it
///    has checked every one, the wording repair (`CardWordingRepairPass`;
///    docs/memory-design.md, "A card stands on its own") rewords a batch of
///    the questions that point at their source unnamed, before rewording
///    below makes variations of them.
/// 5. **Cards that earned it are reworded.** A kept card remembered twice
///    gets its rewordings (`CardVariationPass`; docs/memory-design.md,
///    "Variations").
/// 6. **The watermark moves.** To now when everything succeeded; otherwise to
///    just before the oldest chat that failed, so it is found again — and
///    not at all when the daily background AI limit stopped idea extraction,
///    so the sources it did not reach are read again next time.
///
/// Its paid steps after the chats — idea extraction, drafting, the wording
/// repair and rewording —
/// are background work: each asks `spendAllowed` before it spends and stops at
/// the learner's daily cap, whatever started the close (decisions
/// 2026-09-30). The pass never plans a review itself;
/// `MemoryReviewPreparationRunner` does that after it, so the preparation
/// reads the documents this wrote.
struct DayClosePass: Sendable {
    let storage: StorageService
    let aiService: AIService
    let ideaExtraction: SourceIdeaExtractionService
    /// Whether background AI may spend now: the view model's
    /// `backgroundAISpendAllowed`, which also says once a day when the cap
    /// stops it.
    let spendAllowed: @Sendable () async -> Bool
    /// The background drafting step; nil runs none.
    let drafting: AutomaticCardDraftingPass?
    /// The rewording step; nil runs none.
    let variations: CardVariationPass?
    /// The wording repair of cards kept before the gate; nil runs none.
    let wordingRepair: CardWordingRepairPass?

    /// The closer reads the whole conversation; a very long one is cut to its
    /// tail, where the turns this run has not yet folded in are.
    static let maxTranscriptCharacters = 48_000

    private static let logger = Logger(subsystem: "ForeverLM", category: "DayClose")

    /// `ideaExtraction` is the window's own service when there is one, so a
    /// source the learner just finished, whose ideas it is extracting, is
    /// not extracted twice; nil makes one for this pass.
    init(
        storage: StorageService,
        aiService: AIService,
        ideaExtraction: SourceIdeaExtractionService? = nil,
        spendAllowed: @escaping @Sendable () async -> Bool,
        drafting: AutomaticCardDraftingPass? = nil,
        wordingRepair: CardWordingRepairPass? = nil,
        variations: CardVariationPass?
    ) {
        self.storage = storage
        self.aiService = aiService
        self.ideaExtraction = ideaExtraction ?? SourceIdeaExtractionService(storage: storage, aiService: aiService)
        self.spendAllowed = spendAllowed
        self.drafting = drafting
        self.wordingRepair = wordingRepair
        self.variations = variations
    }

    /// Everything since the watermark. `closeConfig` is the model for the
    /// closer, resolved by the caller (`KeychainService.resolveConfig(for:
    /// .cohortSessionClose)`) so a test can hand in a stub; nil means no chat
    /// is closed this run and the watermark stays where it was.
    func consolidate(now: Date = Date(), closeConfig: AITaskConfig?) async -> DayCloseReport {
        var report = DayCloseReport()
        let since: Date
        do {
            since = try await storage.dayCloseState()?.watermark ?? DayCloseTiming.firstWatermark(now: now)
        } catch {
            report.failures.append("The day could not be closed: \(error.localizedDescription)")
            return report
        }

        var oldestFailedTurn: Date?

        // 1. Chats become understanding.
        let subjects: [KnowledgeStore.DayCloseChatSubject]
        do {
            subjects = try await storage.dayCloseChatSubjects(since: since, now: now)
        } catch {
            report.failures.append("Today's chats could not be listed: \(error.localizedDescription)")
            return report
        }
        if !subjects.isEmpty {
            guard let closeConfig else {
                report.failures.append("The model for closing a chat isn't available. Check Settings › AI Usage.")
                return report
            }
            for subject in subjects {
                do {
                    let updated = try await close(subject, config: closeConfig, now: now)
                    report.consolidatedChats += 1
                    report.updatedUnderstandingDocuments += updated
                } catch {
                    Self.logger.error("Day close could not fold in chat \(subject.sessionID, privacy: .public): \(error.localizedDescription)")
                    report.failures.append("\(subject.title) — \(error.localizedDescription)")
                    oldestFailedTurn = min(oldestFailedTurn ?? subject.lastLearnerTurnAt, subject.lastLearnerTurnAt)
                }
            }
        }

        // 2. Reading gets its ideas. Best effort: a source the model cannot
        // turn into ideas is remembered per device for a day by the extraction
        // service, and the morning drops it from the review and says so.
        // Background spend: stopped at the daily cap, the sources not reached
        // keep the watermark where it was, so the next run reads them again
        // (a source whose ideas match its text costs nothing then).
        var ideasWaiting = 0
        do {
            let consumed = try await storage.sourceIDsConsumed(since: since, now: now)
            for (index, sourceID) in consumed.enumerated() {
                // An audio overview retells its notebook's sources, whose own
                // ideas are what is remembered; its script has none of its own.
                if let source = try? await storage.loadSourceWithoutContent(sourceID),
                   GeneratedAudioOverview.isCarrier(source) { continue }
                guard await spendAllowed() else {
                    ideasWaiting = consumed.count - index
                    break
                }
                do {
                    let ideas = try await ideaExtraction.prepare(sourceID: sourceID)
                    if !ideas.isEmpty { report.warmedSources += 1 }
                } catch {
                    report.failures.append("Ideas for a source could not be extracted: \(error.localizedDescription)")
                }
            }
        } catch {
            report.failures.append("Today's reading could not be listed: \(error.localizedDescription)")
        }
        if ideasWaiting > 0 {
            report.notes.append(ideasWaiting == 1
                ? "The ideas of 1 source wait: today's background AI limit is reached."
                : "The ideas of \(ideasWaiting) sources wait: today's background AI limit is reached.")
        }

        // 2b. What was done becomes working notes and the running log
        // (`WorkingNoteExtractionPass`). Background spend, and soft: a run
        // that cannot write them leaves the watermark alone, because the chats
        // above are what it guards, and tomorrow reads the same activity again.
        if let closeConfig, await spendAllowed() {
            let written = await WorkingNoteExtractionPass(storage: storage, aiService: aiService)
                .run(chats: subjects, since: since, now: now, config: closeConfig)
            report.workingNotesWritten = written.added + written.updated
            if let failure = written.failure { report.notes.append(failure) }
        }

        // 3. Cards are drafted from what was finished.
        if let drafting {
            let drafted = await drafting.run(now: now)
            report.draftedCards = drafted.draftedCards
            report.draftedSources = drafted.draftedSources.count
            report.draftsWaiting = drafted.waiting
            report.notes += drafted.notes
            report.failures += drafted.failures
        }

        // 4. Cards kept before the wording gate stand on their own.
        if let wordingRepair {
            let repaired = await wordingRepair.run(now: now)
            report.standaloneRewordedCards = repaired.reworded
            report.failures += repaired.failures
            if repaired.waiting > 0 {
                report.notes.append(repaired.waiting == 1
                    ? "1 kept card waits to have its wording checked: today's background AI limit is reached."
                    : "\(repaired.waiting) kept cards wait to have their wording checked: today's background AI limit is reached.")
            }
        }

        // 5. Cards that earned it are reworded.
        if let variations {
            let varied = await variations.run(now: now)
            report.rewordedCards = varied.reworded
            report.variedCards = varied.varied
            report.failures += varied.failures
            if varied.waiting > 0 {
                report.notes.append(varied.waiting == 1
                    ? "1 card waits to be reworded: today's background AI limit is reached."
                    : "\(varied.waiting) cards wait to be reworded: today's background AI limit is reached.")
            }
        }

        // 6. The watermark moves — not past sources whose ideas wait.
        let watermark = ideasWaiting > 0
            ? since
            : oldestFailedTurn.map { min($0.addingTimeInterval(-1), now) } ?? now
        do {
            try await storage.recordDayCloseRun(watermark: watermark, now: now)
            report.watermark = watermark
        } catch {
            report.failures.append("The day close could not be recorded: \(error.localizedDescription)")
        }
        Self.logger.notice("Day close folded in \(report.consolidatedChats) chat(s), rewrote \(report.updatedUnderstandingDocuments) document(s), warmed \(report.warmedSources) source(s), drafted \(report.draftedCards) card(s), reworded \(report.rewordedCards) card(s), \(report.failures.count) failure(s)")
        return report
    }

    /// What the source's document should now record as engaged: what earlier
    /// conversations reached, plus what this one did, in the source's own idea
    /// order.
    ///
    /// A union, because two chats a week apart about different halves of a
    /// paper have both been met and neither should erase the other. Held to
    /// the ideas the source carries *now*, so a re-extraction — new content
    /// hash, new ids — retires the old set instead of leaving a document
    /// pointing at ideas that no longer exist. A source whose ideas were not
    /// listed to the closer keeps what it had: nil, meaning "nothing said".
    static func mergedDiscussedIdeaIDs(known brief: CohortSourceBrief?, adding: [String]) -> [String]? {
        guard let brief, !brief.ideas.isEmpty else { return nil }
        let engaged = Set(brief.discussedIdeaIDs).union(adding)
        return brief.ideas.map(\.id).filter { engaged.contains($0) }
    }

    /// One chat through the closer. Returns how many documents were rewritten.
    private func close(_ subject: KnowledgeStore.DayCloseChatSubject, config: AITaskConfig, now: Date) async throws -> Int {
        let sourceIDs = try await storage.dayCloseDiscussedSourceIDs(for: subject)
        guard !sourceIDs.isEmpty else {
            // Nothing to attach understanding to; the turns are read, not lost —
            // the chat is still material of its own (`ReviewableChat`).
            try await storage.recordChatConsolidation(
                sessionID: subject.sessionID, throughSequence: subject.throughSequence, sourceCount: 0, now: now
            )
            return 0
        }
        let briefs = try await storage.cohortBriefs(forSourceIDs: sourceIDs)
        guard !briefs.isEmpty else {
            try await storage.recordChatConsolidation(
                sessionID: subject.sessionID, throughSequence: subject.throughSequence, sourceCount: 0, now: now
            )
            return 0
        }

        var transcript = try await storage.dayCloseTranscript(sessionID: subject.sessionID, title: subject.title)
        if transcript.count > Self.maxTranscriptCharacters {
            transcript = "[earlier turns omitted]\n" + String(transcript.suffix(Self.maxTranscriptCharacters))
        }
        if !subject.isReview {
            transcript = "(This was an ordinary conversation the learner had with ForeverLM, not a review. Record what they asked, what they worked out for themselves, and what they left unresolved; a question they asked is not something they can explain.)\n\n" + transcript
        }

        let result = try await aiService.closeCohortSession(transcript: transcript, briefs: briefs, config: config)

        var updated = 0
        let titles = Dictionary(uniqueKeysWithValues: briefs.map { ($0.source.sourceID, $0.source.title) })
        let briefsBySource = Dictionary(uniqueKeysWithValues: briefs.map { ($0.source.sourceID, $0) })
        for update in result.sources {
            let markdown = update.understandingMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !markdown.isEmpty else { continue }
            try await storage.saveUnderstandingDocument(
                sourceID: update.sourceID,
                title: titles[update.sourceID] ?? update.sourceID,
                markdown: markdown,
                derivedThroughSessionID: subject.sessionID,
                openThreadCount: update.openThreadCount,
                discussedIdeaIDs: Self.mergedDiscussedIdeaIDs(
                    known: briefsBySource[update.sourceID],
                    adding: update.discussedIdeaIDs
                )
            )
            updated += 1
        }
        try await storage.setReviewSessionSummary(sessionID: subject.sessionID, summary: result.sessionSummary)
        try await storage.recordChatConsolidation(
            sessionID: subject.sessionID, throughSequence: subject.throughSequence, sourceCount: sourceIDs.count, now: now
        )
        return updated
    }
}
