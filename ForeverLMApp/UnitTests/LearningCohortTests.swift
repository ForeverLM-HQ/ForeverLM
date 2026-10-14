import Foundation
import Testing
@testable import ForeverLM

// MARK: - Selection

@Suite("Cohort selection")
struct CohortSelectorTests {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func candidate(
        _ id: String,
        consumedDaysAgo: Int,
        reviewCount: Int = 0,
        discussedDaysAgo: Int? = nil
    ) -> CohortCandidate {
        CohortCandidate(
            sourceID: id,
            title: "Source \(id)",
            sourceType: "paper",
            consumedAt: now.addingTimeInterval(-Double(consumedDaysAgo) * 86_400),
            confidence: .substantial,
            reviewCount: reviewCount,
            lastDiscussedAt: discussedDaysAgo.map { now.addingTimeInterval(-Double($0) * 86_400) }
        )
    }

    @Test("Recently consumed and never reviewed is the spine")
    func recentUndiscussedIsSpine() {
        let selection = CohortSelector.select(
            candidates: [candidate("a", consumedDaysAgo: 2), candidate("b", consumedDaysAgo: 9)],
            now: now
        )
        #expect(selection.spine.map(\.sourceID) == ["a", "b"])
        #expect(selection.spacing.isEmpty)
    }

    @Test("A backlog source consumed before the window still becomes due")
    func backlogBecomesSpacing() {
        // Without this, a paper read three weeks ago and never reviewed would
        // never become due at all — it falls out of the window and has no
        // review history to schedule from.
        let selection = CohortSelector.select(
            candidates: [candidate("old", consumedDaysAgo: 40)],
            now: now
        )
        #expect(selection.spine.isEmpty)
        #expect(selection.spacing.map(\.sourceID) == ["old"])
    }

    @Test("A discussed source waits for its own interval")
    func intervalsExpand() {
        // reviewCount 1 → 3 days, reviewCount 3 → 21 days.
        let notYet = candidate("fresh", consumedDaysAgo: 30, reviewCount: 1, discussedDaysAgo: 1)
        let due = candidate("due", consumedDaysAgo: 30, reviewCount: 1, discussedDaysAgo: 4)
        let longNotYet = candidate("long", consumedDaysAgo: 90, reviewCount: 3, discussedDaysAgo: 10)
        let longDue = candidate("longdue", consumedDaysAgo: 90, reviewCount: 3, discussedDaysAgo: 25)

        let selection = CohortSelector.select(
            candidates: [notYet, due, longNotYet, longDue],
            now: now
        )
        #expect(Set(selection.spacing.map(\.sourceID)) == ["due", "longdue"])
    }

    @Test("Intervals stop expanding rather than dropping a source forever")
    func intervalsCap() {
        #expect(CohortSelector.interval(forReviewCount: 0) == 1)
        #expect(CohortSelector.interval(forReviewCount: 1) == 3)
        #expect(CohortSelector.interval(forReviewCount: 5) == 180)
        #expect(CohortSelector.interval(forReviewCount: 50) == 180)
    }

    @Test("The most overdue source comes first, measured against its own interval")
    func spacingSortsByOverdueRatio() {
        // 10 days late on a 3-day interval outranks 30 days late on a 180-day one.
        let short = candidate("short", consumedDaysAgo: 60, reviewCount: 1, discussedDaysAgo: 13)
        let long = candidate("long", consumedDaysAgo: 300, reviewCount: 5, discussedDaysAgo: 210)
        let selection = CohortSelector.select(candidates: [long, short], now: now)
        #expect(selection.spacing.first?.sourceID == "short")
    }

    @Test("Caps are enforced and what was dropped is counted, not swallowed")
    func capsAreReported() {
        // Older than yesterday, so nothing here is guaranteed a pass.
        let spine = (0..<9).map { candidate("new-\($0)", consumedDaysAgo: 2 + $0 % 5) }
        let spacing = (0..<7).map {
            candidate("old-\($0)", consumedDaysAgo: 200, reviewCount: 1, discussedDaysAgo: 30 + $0)
        }
        // Fifteen minutes: five slots, one of them kept for material due again.
        let selection = CohortSelector.select(candidates: spine + spacing, now: now, budgetMinutes: 15)

        #expect(selection.spine.count == 4)
        #expect(selection.spacing.count == 1)
        #expect(selection.droppedSpine == 9 - 4)
        #expect(selection.droppedSpacing == 7 - 1)
    }

    @Test("Yesterday's reading is never cut by the budget")
    func yesterdaysReadingIsGuaranteedAPass() {
        // A heavy day: eight sources taken in since yesterday, three from earlier
        // in the window, and material due again.
        let yesterday = (0..<8).map { candidate("fresh-\($0)", consumedDaysAgo: $0 % 2) }
        let older = (0..<3).map { candidate("older-\($0)", consumedDaysAgo: 3 + $0) }
        let due = (0..<4).map {
            candidate("due-\($0)", consumedDaysAgo: 200, reviewCount: 1, discussedDaysAgo: 30 + $0)
        }
        // Fifteen minutes is five slots; yesterday alone needs eight.
        let selection = CohortSelector.select(candidates: yesterday + older + due, now: now, budgetMinutes: 15)

        #expect(Set(selection.spine.map(\.sourceID)) == Set(yesterday.map(\.sourceID)))
        // Freshest first, as the session opens on what is freshest in mind.
        #expect(selection.spine.first?.sourceID == "fresh-0")
        #expect(selection.spacing.isEmpty)
        // What was cut is the older reading and the due set, and it is counted.
        #expect(selection.droppedSpine == older.count)
        #expect(selection.droppedSpacing == due.count)
        // The guarantee is said in the reason, so the tutor goes lighter per
        // source rather than leaving one out.
        let reason = CohortSelector.reason(for: .spine, candidate: yesterday[1], now: now)
        #expect(reason.contains("first pass is guaranteed today"))
        #expect(!CohortSelector.reason(for: .spine, candidate: older[0], now: now).contains("guaranteed"))

        // With room to spare, the guaranteed passes take their slots first and
        // the rest of the budget is shared as before.
        let roomy = CohortSelector.select(candidates: yesterday + older + due, now: now, budgetMinutes: 60)
        #expect(roomy.spine.count == yesterday.count + older.count)
        #expect(roomy.spacing.count == due.count)
        #expect(roomy.droppedSpine == 0)

        // A source already discussed is on the ladder, not owed a first pass.
        let discussedYesterday = candidate("graded", consumedDaysAgo: 1, reviewCount: 1, discussedDaysAgo: 0)
        #expect(!CohortSelector.isGuaranteedPass(discussedYesterday, now: now))
        // Two days is the edge: still owed the day after a missed review, not beyond.
        #expect(CohortSelector.isGuaranteedPass(candidate("edge", consumedDaysAgo: 1), now: now))
        #expect(!CohortSelector.isGuaranteedPass(candidate("past", consumedDaysAgo: 2), now: now))
    }

    @Test("A bulk import does not turn the guarantee into a review over every source")
    func guaranteedPassesAreBoundedByTheLongestBudget() {
        // 2026-09-08: a Notebook's worth of papers imported the day before made
        // 166 never-discussed sources "yesterday's reading" at once.
        let imported = (0..<166).map { candidate("import-\($0)", consumedDaysAgo: 1) }
        let older = (0..<3).map { candidate("older-\($0)", consumedDaysAgo: 4 + $0) }
        let due = (0..<4).map {
            candidate("due-\($0)", consumedDaysAgo: 200, reviewCount: 1, discussedDaysAgo: 30 + $0)
        }
        let ceiling = CohortSelector.maxGuaranteedPasses
        // Two hours at three minutes a source.
        #expect(ceiling == 40)

        let selection = CohortSelector.select(candidates: imported + older + due, now: now, budgetMinutes: 15)
        // The review carries the ceiling and no more, all of it from the import:
        // the guaranteed passes still outrank the older reading and the due set.
        #expect(selection.spine.count == ceiling)
        #expect(selection.spine.allSatisfy { $0.sourceID.hasPrefix("import-") })
        #expect(selection.spacing.isEmpty)
        // What did not fit is counted, so the tutor can say so.
        #expect(selection.droppedSpine == imported.count - ceiling + older.count)
        #expect(selection.droppedSpacing == due.count)

        // Under the ceiling the guarantee is untouched: a heavy day still gets
        // every one of its sources, as before.
        let heavy = (0..<30).map { candidate("heavy-\($0)", consumedDaysAgo: 1) }
        let heavyDay = CohortSelector.select(candidates: heavy + older + due, now: now, budgetMinutes: 15)
        #expect(heavyDay.spine.count == heavy.count)
        #expect(heavyDay.droppedSpine == older.count)
    }

    @Test("The daily budget decides how many sources and bridges a review carries")
    func budgetSizesTheReview() {
        // About three minutes a source at the standard depth, never fewer than two.
        #expect(MemoryReviewBudget.sourceSlots(minutes: 5) == 2)
        #expect(MemoryReviewBudget.sourceSlots(minutes: 10) == 3)
        #expect(MemoryReviewBudget.sourceSlots(minutes: 15) == 5)
        #expect(MemoryReviewBudget.sourceSlots(minutes: 30) == 10)
        #expect(MemoryReviewBudget.sourceSlots(minutes: 60) == 20)
        // A bridge is a connect question at the end, only when there is room.
        #expect(MemoryReviewBudget.bridgeSlots(minutes: 10) == 0)
        #expect(MemoryReviewBudget.bridgeSlots(minutes: 15) == 1)
        #expect(MemoryReviewBudget.bridgeSlots(minutes: 30) == 2)
        #expect(CohortSelector.maxBridges(budgetMinutes: 15) == 1)
        // Out-of-range values from another client are clamped, not trusted.
        #expect(MemoryReviewBudget.clamp(0) == MemoryReviewBudget.minimumMinutes)
        #expect(MemoryReviewBudget.clamp(600) == MemoryReviewBudget.maximumMinutes)
        #expect(MemoryReviewBudget.label(15) == "15 minutes")
        #expect(MemoryReviewBudget.label(60) == "1 hour")
        #expect(MemoryReviewBudget.label(90) == "1 hour 30 minutes")
        // What Settings says the budget buys.
        #expect(MemoryReviewBudget.summary(minutes: 15) == "15 minutes is room for about five sources and one bridge question.")
        #expect(MemoryReviewBudget.summary(minutes: 30) == "30 minutes is room for about ten sources and two bridge questions.")
        #expect(MemoryReviewBudget.summary(minutes: 5) == "5 minutes is room for about two sources, with no bridge question.")
    }

    @Test("Slots one side leaves empty go to the other, and something due always gets one")
    func budgetSlotsAreShared() {
        // Nothing due: recent reading takes every slot.
        #expect(CohortSelector.caps(budgetMinutes: 15, spineCount: 9, spacingCount: 0) == .init(spine: 5, spacing: 0))
        // Nothing new: material due again takes every slot.
        #expect(CohortSelector.caps(budgetMinutes: 15, spineCount: 0, spacingCount: 9) == .init(spine: 0, spacing: 5))
        // Both waiting: about a third is kept for what is due.
        #expect(CohortSelector.caps(budgetMinutes: 30, spineCount: 9, spacingCount: 9) == .init(spine: 7, spacing: 3))
        // Little new reading: the spacing set fills what the spine left.
        #expect(CohortSelector.caps(budgetMinutes: 15, spineCount: 1, spacingCount: 9) == .init(spine: 1, spacing: 4))
        // The shortest budget still keeps one of each in play.
        #expect(CohortSelector.caps(budgetMinutes: 5, spineCount: 9, spacingCount: 9) == .init(spine: 1, spacing: 1))

        // Reading from earlier in the window, so the budget is what decides.
        let spine = (0..<3).map { candidate("new-\($0)", consumedDaysAgo: 3 + $0) }
        let due = candidate("old", consumedDaysAgo: 200, reviewCount: 1, discussedDaysAgo: 30)
        let selection = CohortSelector.select(candidates: spine + [due], now: now, budgetMinutes: 5)
        #expect(selection.spine.map(\.sourceID) == ["new-0"])
        #expect(selection.spacing.map(\.sourceID) == ["old"])
        #expect(selection.droppedSpine == 2)
        // Zero slots left over is zero of each, never a negative cap.
        #expect(CohortSelector.caps(slots: 0, spineCount: 4, spacingCount: 4) == .init(spine: 0, spacing: 0))
    }

    @Test("Selection is deterministic for identical input")
    func selectionIsDeterministic() {
        let candidates = (0..<12).map { candidate("s-\($0)", consumedDaysAgo: $0 % 4) }
        let first = CohortSelector.select(candidates: candidates, now: now)
        let second = CohortSelector.select(candidates: candidates.reversed(), now: now)
        #expect(first.spine.map(\.sourceID) == second.spine.map(\.sourceID))
    }

    @Test("A review count with no timestamp is treated as due, not dropped")
    func incoherentHistoryIsStillDue() {
        let broken = CohortCandidate(
            sourceID: "broken",
            title: "Broken",
            sourceType: "paper",
            consumedAt: now.addingTimeInterval(-90 * 86_400),
            confidence: .complete,
            reviewCount: 2,
            lastDiscussedAt: nil
        )
        let selection = CohortSelector.select(candidates: [broken], now: now)
        #expect(selection.spacing.map(\.sourceID) == ["broken"])
    }

    @Test("A partial bridge says so, rather than quizzing unread material")
    func partialBridgeIsAnnounced() {
        let partial = CohortCandidate(
            sourceID: "p", title: "Half read", sourceType: "book",
            consumedAt: now.addingTimeInterval(-60 * 86_400),
            confidence: .partial, reviewCount: 0, lastDiscussedAt: nil
        )
        let whole = CohortCandidate(
            sourceID: "w", title: "Finished", sourceType: "book",
            consumedAt: now.addingTimeInterval(-60 * 86_400),
            confidence: .complete, reviewCount: 0, lastDiscussedAt: nil
        )
        #expect(CohortSelector.reason(for: .bridge, candidate: partial, now: now)
            .contains("only got part of the way"))
        #expect(CohortSelector.reason(for: .bridge, candidate: whole, now: now)
            .contains("only got part of the way") == false)
    }

    @Test("Time buckets separate this week from months ago")
    func timeBuckets() {
        #expect(CohortSelector.timeBucket(now.addingTimeInterval(-2 * 86_400), now: now) == 0)
        #expect(CohortSelector.timeBucket(now.addingTimeInterval(-30 * 86_400), now: now) == 1)
        #expect(CohortSelector.timeBucket(now.addingTimeInterval(-100 * 86_400), now: now) == 2)
        #expect(CohortSelector.timeBucket(now.addingTimeInterval(-400 * 86_400), now: now) == 3)
    }
}

// MARK: - Plan validation

@Suite("Cohort session plan")
struct CohortSessionPlanTests {

    private func cohort(sourceIDs: [String]) -> LearningCohort {
        LearningCohort(
            assembledAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            windowDays: CohortSelector.windowDays,
            sources: sourceIDs.map { id in
                CohortSource(
                    sourceID: id,
                    title: id,
                    sourceType: "paper",
                    role: .spine,
                    consumedAt: nil,
                    lastDiscussedAt: nil,
                    reviewCount: 0,
                    confidence: .complete,
                    bridgeTo: nil,
                    reason: "test"
                )
            },
            unfinished: [],
            droppedSpine: 0,
            droppedSpacing: 0
        )
    }

    @Test("A move naming a source outside the cohort is dropped")
    func rejectsUnknownSources() {
        let plan = CohortSessionPlan(
            opening: "Today",
            moves: [
                CohortMove(kind: .explain, sourceIDs: ["a"], intent: "fine"),
                CohortMove(kind: .connect, sourceIDs: ["a", "ghost"], intent: "hallucinated"),
                CohortMove(kind: .recall, sourceIDs: [], intent: "empty"),
            ]
        )
        let validated = plan.validated(against: cohort(sourceIDs: ["a", "b"]))
        #expect(validated.moves.count == 1)
        #expect(validated.moves[0].intent == "fine")
    }

    @Test("A cross-source move is recognized as connecting")
    func detectsCrossSourceMoves() {
        let single = CohortSessionPlan(
            opening: "x",
            moves: [CohortMove(kind: .recall, sourceIDs: ["a"], intent: "i")]
        )
        let spanning = CohortSessionPlan(
            opening: "x",
            moves: [CohortMove(kind: .connect, sourceIDs: ["a", "b"], intent: "i")]
        )
        #expect(single.connectsAcrossSources == false)
        #expect(spanning.connectsAcrossSources)
    }

    @Test("Closing updates for untouched sources are discarded")
    func closeRejectsUntouchedSources() {
        let result = CohortCloseResult(
            sessionSummary: "s",
            sources: [
                .init(sourceID: "a", understandingMarkdown: "kept", openThreadCount: 1),
                .init(sourceID: "z", understandingMarkdown: "dropped", openThreadCount: 0),
            ]
        )
        let validated = result.validated(against: ["a"])
        #expect(validated.sources.map(\.sourceID) == ["a"])
    }

    @Test("Plan JSON from the model decodes")
    func decodesPlanJSON() throws {
        let json = """
        {"opening": "Two papers on GDF15.",
         "moves": [{"kind": "connect", "source_ids": ["a", "b"], "intent": "Reconcile them."}]}
        """
        let plan = try JSONDecoder().decode(CohortSessionPlan.self, from: Data(json.utf8))
        #expect(plan.moves.first?.kind == .connect)
        #expect(plan.moves.first?.sourceIDs == ["a", "b"])
    }
}

// MARK: - Nudge

@Suite("Cohort nudge")
struct CohortNudgeTests {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func cohort(_ ids: [String]) -> LearningCohort {
        LearningCohort(
            assembledAt: now,
            windowDays: 10,
            sources: ids.map {
                CohortSource(
                    sourceID: $0, title: $0, sourceType: "paper", role: .spine,
                    consumedAt: now, lastDiscussedAt: nil, reviewCount: 0,
                    confidence: .complete, bridgeTo: nil, reason: "test"
                )
            },
            unfinished: [],
            droppedSpine: 0,
            droppedSpacing: 0
        )
    }

    @Test("The signature identifies the material, not the order it arrived in")
    func signatureIsOrderIndependent() {
        #expect(
            CohortNudge.signature(for: cohort(["a", "b"]))
            == CohortNudge.signature(for: cohort(["b", "a"]))
        )
        #expect(
            CohortNudge.signature(for: cohort(["a", "b"]))
            != CohortNudge.signature(for: cohort(["a", "c"]))
        )
    }

    @Test("Dismissing today's material does not silence tomorrow's")
    func dismissalIsKeyedToMaterial() {
        let today = cohort(["a", "b"])
        let tomorrow = cohort(["a", "b", "c"])
        CohortNudge.restoreAll()
        defer { CohortNudge.restoreAll() }

        CohortNudge.dismiss(signature: CohortNudge.signature(for: today))

        #expect(CohortNudge.decide(cohort: today) == .dismissed(signature: CohortNudge.signature(for: today)))
        if case .offer = CohortNudge.decide(cohort: tomorrow) {} else {
            Issue.record("A different cohort must be offered afresh")
        }
    }

    @Test("A dismissal can always be undone")
    func dismissalIsReversible() {
        let today = cohort(["a"])
        let signature = CohortNudge.signature(for: today)
        CohortNudge.restoreAll()
        defer { CohortNudge.restoreAll() }

        CohortNudge.dismiss(signature: signature)
        #expect(CohortNudge.isDismissed(signature: signature))
        CohortNudge.restore(signature: signature)
        #expect(CohortNudge.isDismissed(signature: signature) == false)
    }

    @Test("Yesterday's dismissal does not silence today")
    func dismissalsExpireDaily() {
        let yesterday = now.addingTimeInterval(-86_400)
        let entries = ["old": yesterday.timeIntervalSinceReferenceDate,
                       "today": now.timeIntervalSinceReferenceDate]
        let pruned = CohortNudge.pruned(entries, now: now)
        #expect(pruned["old"] == nil)
        #expect(pruned["today"] != nil)
    }

    @Test("An empty cohort is never offered")
    func emptyCohortIsSilent() {
        #expect(CohortNudge.decide(cohort: cohort([])) == .nothingDue)
    }

    @Test("The daily notification is off until switched on")
    func notificationsAreOptIn() {
        // A channel that was retired wholesale must not quietly come back. The
        // switch is the daily preparation's now, and the test host shares this
        // Mac's Dev defaults, so the row is cleared for the check and put back.
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: DailyReviewPreparation.enabledKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: DailyReviewPreparation.enabledKey)
            } else {
                defaults.removeObject(forKey: DailyReviewPreparation.enabledKey)
            }
        }
        defaults.removeObject(forKey: "cohortReview.dailyNotification.enabled.v1")
        defaults.removeObject(forKey: DailyReviewPreparation.enabledKey)
        #expect(CohortReviewNotifications.isEnabled == false)
    }
}

// MARK: - Understanding documents

@Suite("Understanding documents")
struct UnderstandingDocumentTests {

    @Test("Filenames are readable but identified by the portable key")
    func fileNaming() {
        let name = UnderstandingDocumentPaths.fileName(
            title: "Hallmarks of Aging: An Expanding Universe",
            portableSourceKey: "abcdef0123456789"
        )
        #expect(name == "hallmarks-of-aging-an-expanding-universe-23456789.md")
    }

    @Test("A title with nothing sluggable still yields a stable filename")
    func degeneateTitle() {
        let name = UnderstandingDocumentPaths.fileName(title: "…!?", portableSourceKey: "key12345")
        #expect(name == "source-key12345.md")
    }

    @Test("iCloud conflict copies are recognized, deliberate siblings are not")
    func conflictSiblings() {
        let canonical = "notes-ab12cd34.md"
        #expect(UnderstandingDocumentPaths.isConflictSibling(fileName: "notes-ab12cd34 2.md", of: canonical))
        #expect(UnderstandingDocumentPaths.isConflictSibling(
            fileName: "notes-ab12cd34 (Mac's conflicted copy 2026-08-18).md",
            of: canonical
        ))
        #expect(UnderstandingDocumentPaths.isConflictSibling(fileName: canonical, of: canonical) == false)
        // A file the learner made themselves must not be eaten as a conflict.
        #expect(UnderstandingDocumentPaths.isConflictSibling(fileName: "notes-ab12cd34-extra.md", of: canonical) == false)
    }

    @Test("A document edited by hand is detectable")
    func detectsLearnerEdits() {
        let body = "# Source\n\nThey can explain the mechanism."
        var document = UnderstandingDocument(
            sourceID: "s",
            relativePath: "Understanding/s.md",
            markdown: body,
            derivedThroughSessionID: nil,
            generatedAt: Date(),
            generatorVersion: 1,
            bodySHA256: UnderstandingDocument.digest(body),
            openThreadCount: 0
        )
        #expect(document.hasLearnerEdits == false)
        document.markdown = body + "\n\nActually I do get this."
        #expect(document.hasLearnerEdits)
    }
}

// MARK: - Storage

@Suite("Understanding storage", .serialized)
struct UnderstandingStorageTests {

    /// Redirects document writes away from the learner's real iCloud Drive.
    private func withTemporaryRoot<T>(_ body: (URL) throws -> T) rethrows -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UnderstandingTests_\(UUID().uuidString)")
        KnowledgeStore.understandingRootOverride = root.path
        defer {
            KnowledgeStore.understandingRootOverride = nil
            try? FileManager.default.removeItem(at: root)
        }
        return try body(root)
    }

    private func makeSource(_ store: KnowledgeStore, url: String, title: String) throws -> StudioArticle {
        var article = StudioArticle(url: url, title: title)
        article.normalizedURL = URLNormalizer.normalize(url)
        article.content = String(repeating: "Body worth reviewing. ", count: 20)
        try store.saveSource(article)
        return article
    }

    @Test("A document round-trips through disk and its index row")
    func roundTrip() throws {
        try withTemporaryRoot { root in
            let store = try KnowledgeStore(inMemory: true)
            let article = try makeSource(store, url: "https://example.com/u1", title: "Aging Hallmarks")

            let written = try store.saveUnderstandingDocument(
                sourceID: article.id,
                title: article.title,
                markdown: "# Aging Hallmarks\n\nThey can explain autophagy.",
                derivedThroughSessionID: "session-1",
                openThreadCount: 2
            )
            #expect(written.relativePath.hasPrefix("Understanding/"))
            #expect(FileManager.default.fileExists(
                atPath: root.appendingPathComponent(written.relativePath).path
            ))

            let loaded = try #require(try store.loadUnderstandingDocument(sourceID: article.id))
            #expect(loaded.markdown.contains("autophagy"))
            #expect(loaded.derivedThroughSessionID == "session-1")
            #expect(loaded.openThreadCount == 2)
            #expect(loaded.hasLearnerEdits == false)
            #expect(try store.unfinishedUnderstandingSourceIDs() == [article.id])
        }
    }

    @Test("An edit made in a text editor is read back, not overwritten blind")
    func learnerEditsSurvive() throws {
        try withTemporaryRoot { root in
            let store = try KnowledgeStore(inMemory: true)
            let article = try makeSource(store, url: "https://example.com/u2", title: "Edited")
            let written = try store.saveUnderstandingDocument(
                sourceID: article.id,
                title: article.title,
                markdown: "# Edited\n\nVague on the mechanism.",
                derivedThroughSessionID: nil
            )

            // The learner opens the file and corrects it.
            let path = root.appendingPathComponent(written.relativePath).path
            try "# Edited\n\nI actually do get this, I explained it badly."
                .write(toFile: path, atomically: true, encoding: .utf8)

            let reloaded = try #require(try store.loadUnderstandingDocument(sourceID: article.id))
            #expect(reloaded.hasLearnerEdits)
            #expect(reloaded.markdown.contains("explained it badly"))
        }
    }

    @Test("A retitled source keeps writing to the file it already has")
    func pathIsStableAcrossRetitle() throws {
        try withTemporaryRoot { _ in
            let store = try KnowledgeStore(inMemory: true)
            let article = try makeSource(store, url: "https://example.com/u3", title: "First Title")
            let first = try store.saveUnderstandingDocument(
                sourceID: article.id, title: "First Title", markdown: "a", derivedThroughSessionID: nil
            )
            let second = try store.saveUnderstandingDocument(
                sourceID: article.id, title: "Completely Different Title", markdown: "b", derivedThroughSessionID: nil
            )
            #expect(first.relativePath == second.relativePath)
        }
    }

    @Test("iCloud conflict copies are found without eating deliberate files")
    func findsConflictCopies() throws {
        try withTemporaryRoot { root in
            let store = try KnowledgeStore(inMemory: true)
            let article = try makeSource(store, url: "https://example.com/u4", title: "Conflicted")
            let written = try store.saveUnderstandingDocument(
                sourceID: article.id, title: article.title, markdown: "canonical", derivedThroughSessionID: nil
            )

            let directory = root.appendingPathComponent("Understanding")
            let stem = ((written.relativePath as NSString).lastPathComponent as NSString)
                .deletingPathExtension
            try "from the other Mac".write(
                to: directory.appendingPathComponent("\(stem) 2.md"),
                atomically: true, encoding: .utf8
            )
            try "mine".write(
                to: directory.appendingPathComponent("\(stem)-scratch.md"),
                atomically: true, encoding: .utf8
            )

            let copies = try store.understandingConflictCopies(sourceID: article.id)
            #expect(copies.count == 1)
            #expect(copies[0].hasSuffix("\(stem) 2.md"))

            let resolved = try store.resolveUnderstandingConflicts(
                sourceID: article.id,
                title: article.title,
                reconciledMarkdown: "merged",
                conflictPaths: copies,
                derivedThroughSessionID: nil
            )
            #expect(resolved.markdown == "merged")
            #expect(try store.understandingConflictCopies(sourceID: article.id).isEmpty)
            // The learner's own file is untouched.
            #expect(FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("\(stem)-scratch.md").path
            ))
        }
    }
}

@Suite("Cohort candidates")
struct CohortCandidateTests {

    private func makeSource(_ store: KnowledgeStore, url: String, title: String) throws -> StudioArticle {
        var article = StudioArticle(url: url, title: title)
        article.normalizedURL = URLNormalizer.normalize(url)
        article.content = String(repeating: "Body worth reviewing. ", count: 20)
        try store.saveSource(article)
        return article
    }

    @Test("Only substantially consumed sources become candidates")
    func consumptionGatesCandidates() throws {
        let store = try KnowledgeStore(inMemory: true)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

        let untouched = try makeSource(store, url: "https://example.com/c1", title: "Untouched")
        let skimmed = try makeSource(store, url: "https://example.com/c2", title: "Skimmed")
        let listened = try makeSource(store, url: "https://example.com/c3", title: "Listened")

        _ = try store.recordScheduledSourceActivity(
            sourceID: skimmed.id, on: now.addingTimeInterval(-86_400), kind: .listening, fraction: 0.2
        )
        // Depth with the time to back it: eight tenths of the way through and
        // ten minutes listening.
        _ = try store.recordScheduledSourceActivity(
            sourceID: listened.id, on: now.addingTimeInterval(-86_400), kind: .listening, fraction: 0.8,
            engagedSeconds: 600
        )

        let candidates = try store.cohortCandidates(now: now)
        #expect(candidates.map(\.sourceID) == [listened.id])
        #expect(candidates.first?.confidence == .substantial)
        #expect(candidates.first?.engagement.engagedSeconds == 600)
        #expect(candidates.first?.engagement.depth == 0.8)
        _ = untouched
    }

    @Test("A memory review's record may name a chat as material; the junction sees only its sources, and creating it reviews nothing")
    func memoryReviewRecordCarriesAChat() throws {
        let store = try KnowledgeStore(inMemory: true)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let paper = try makeSource(store, url: "https://example.com/m1", title: "Paper")
        let sessionID = MemoryReviewSession.sessionID(for: now)

        // A chat's id is not a `sources` row, so the junction's foreign key
        // would refuse it; the record must carry it anyway, in cohort order.
        try store.createReviewSession(
            id: sessionID, topic: "Review", sourceIDs: ["chat-1", paper.id],
            scheduleActivityAt: now, scheduleActivityKind: .review
        )
        let record = try #require(try store.loadReviewSessionLinks().first { $0.id == sessionID })
        #expect(record.sourceIDs == ["chat-1", paper.id])
        #expect(try junctionSourceIDs(store, sessionID: sessionID) == [paper.id])
        // Material is not a review: nothing is put on the Schedule, and
        // History has no "Reviewed" row, until an answer is graded.
        #expect(try store.scheduledSourceID(forSource: paper.id) == nil)
        #expect(try store.scheduledSourceID(forSource: "chat-1") == nil)
        #expect(try store.loadSourceActivityDays(sourceID: paper.id).isEmpty)

        // Attaching a source beside the material keeps the chat in the record.
        try store.updateReviewSessionSources(sessionID: sessionID, sourceIDs: ["chat-1", paper.id, paper.id])
        #expect(try junctionSourceIDs(store, sessionID: sessionID) == [paper.id])

        // An ordinary chat is held to the foreign key as before.
        #expect(throws: (any Error).self) {
            try store.createReviewSession(id: "plain", topic: "Chat", sourceIDs: ["chat-1"])
        }
    }

    private func junctionSourceIDs(_ store: KnowledgeStore, sessionID: String) throws -> [String] {
        var ids: [String] = []
        try store.queryBind(
            "SELECT source_id FROM review_session_sources WHERE session_id = ? ORDER BY source_id",
            bind: { stmt in store.bind(stmt, 1, sessionID) }
        ) { stmt in
            if let id = store.string(stmt, 0) { ids.append(id) }
        }
        return ids
    }

    @Test("A position reached with no time behind it is not consumption; time booked later makes it so")
    func depthNeedsTime() throws {
        let store = try KnowledgeStore(inMemory: true)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let paged = try makeSource(store, url: "https://example.com/c10", title: "Paged to the end")
        let yesterday = now.addingTimeInterval(-86_400)

        // One write at the last page: a skim.
        _ = try store.recordScheduledSourceActivity(sourceID: paged.id, on: yesterday, kind: .reading, fraction: 1.0)
        let skimmed = try store.cohortCandidates(now: now, minimumConfidence: .partial)
        #expect(skimmed.map(\.sourceID) == [paged.id])
        #expect(skimmed.first?.confidence == .partial)
        #expect(try store.cohortCandidates(now: now).isEmpty)

        // Engaged seconds accrue across writes on the same day.
        _ = try store.recordScheduledSourceActivity(sourceID: paged.id, on: yesterday, kind: .reading, engagedSeconds: 70)
        _ = try store.recordScheduledSourceActivity(sourceID: paged.id, on: yesterday, kind: .reading, engagedSeconds: 70)
        #expect(try store.sourceEngagedSeconds(sourceID: paged.id) == 140)
        let read = try #require(try store.cohortCandidates(now: now).first)
        #expect(read.confidence == .complete)
        #expect(read.engagement.engagedSeconds == 140)

        // Rows from before the column fall back to the day's span.
        let spanned = try makeSource(store, url: "https://example.com/c11", title: "Spanned")
        _ = try store.recordScheduledSourceActivity(sourceID: spanned.id, on: yesterday, kind: .reading, fraction: 0.1)
        _ = try store.recordScheduledSourceActivity(
            sourceID: spanned.id, on: yesterday.addingTimeInterval(300), kind: .reading, fraction: 0.7
        )
        #expect(try store.sourceEngagedSeconds(sourceID: spanned.id) == 300)
        #expect(try store.cohortCandidates(now: now).first { $0.sourceID == spanned.id }?.confidence == .substantial)
    }

    @Test("A source in a chat the learner wrote in is consumed and ranked first; a quiz or a memory review is not a chat")
    func chatDiscussionIsEvidence() throws {
        let store = try KnowledgeStore(inMemory: true)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let talked = now.addingTimeInterval(-3_600 * 20)
        let attached = try makeSource(store, url: "https://example.com/c12", title: "Attached to a chat")
        let cited = try makeSource(store, url: "https://example.com/c13", title: "Cited in the reply")
        let quizzed = try makeSource(store, url: "https://example.com/c14", title: "Quizzed")
        let reviewed = try makeSource(store, url: "https://example.com/c15", title: "In the memory review")
        let silent = try makeSource(store, url: "https://example.com/c16", title: "Attached, nothing said")
        let deepRead = try makeSource(store, url: "https://example.com/c17", title: "Read at length")

        // Opened on one source, so that source is the subject; the reply
        // cites a second one by link. The exchange's `source_refs` carry the
        // attached set and are not evidence of anything.
        try store.createReviewSession(id: "chat-1", topic: "About it", sourceIDs: [attached.id], startedAt: talked)
        _ = try store.addReviewExchange(
            sessionID: "chat-1", question: "", answer: "What does it argue?",
            evaluation: "It argues, as [the other](foreverlm://source/\(cited.id)) does.",
            score: nil, knowledgeNote: nil, sourceRefs: [attached.id, cited.id], answeredAt: talked
        )
        try store.createReviewSession(id: "quiz-1", topic: "Quiz", sourceIDs: [quizzed.id], startedAt: talked)
        _ = try store.addReviewExchange(
            sessionID: "quiz-1", question: "Q?", answer: "A.", evaluation: "Good.",
            score: 0.9, knowledgeNote: nil, sourceRefs: [quizzed.id], answeredAt: talked
        )
        let memoryID = MemoryReviewSession.sessionID(for: talked)
        try store.createReviewSession(id: memoryID, topic: "Memory", sourceIDs: [reviewed.id], startedAt: talked)
        _ = try store.addReviewExchange(
            sessionID: memoryID, question: "Recall?", answer: "Some.", evaluation: "Partly.",
            score: nil, knowledgeNote: nil, sourceRefs: [reviewed.id], answeredAt: talked
        )
        try store.createReviewSession(id: "chat-2", topic: "Opened and left", sourceIDs: [silent.id], startedAt: talked)
        _ = try store.recordScheduledSourceActivity(
            sourceID: deepRead.id, on: talked, kind: .reading, fraction: 0.95, engagedSeconds: 3_000
        )

        let candidates = try store.cohortCandidates(now: now).filter { $0.sourceType != ReviewableChat.sourceType }
        let ids = Set(candidates.map(\.sourceID))
        #expect(ids == [attached.id, cited.id, deepRead.id])
        for id in [attached.id, cited.id] {
            let candidate = try #require(candidates.first { $0.sourceID == id })
            #expect(candidate.confidence == .substantial)
            #expect(candidate.consumedAt == talked)
            #expect(candidate.engagement.chatDiscussedAt == talked)
            #expect(candidate.reviewCount == 0)
        }

        // The chat-discussed sources lead the spine; the long read follows.
        let selection = CohortSelector.select(candidates: candidates, now: now)
        #expect(Set(selection.spine.prefix(2).map(\.sourceID)) == [attached.id, cited.id])
        #expect(selection.spine.last?.sourceID == deepRead.id)
        let reason = CohortSelector.reason(for: .spine, candidate: selection.spine[0], now: now)
        #expect(reason.contains("DISCUSSED IN A CHAT"))
    }

    @Test("A broad question across a Notebook's sources vouches for none of them; the reply's citations do")
    func broadNotebookChatIsNotDiscussion() throws {
        let store = try KnowledgeStore(inMemory: true)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let talked = now.addingTimeInterval(-3_600 * 20)
        let shelf = try (1...4).map { try makeSource(store, url: "https://example.com/shelf\($0)", title: "Shelf \($0)") }
        let elsewhere = try makeSource(store, url: "https://example.com/elsewhere", title: "Found by search")

        // The whole Notebook attached, one question, a reply citing one of
        // them and one source the tutor searched up.
        try store.createReviewSession(id: "notebook-chat", topic: "Membrane potentials", sourceIDs: shelf.map(\.id), startedAt: talked)
        _ = try store.addReviewExchange(
            sessionID: "notebook-chat", question: "",
            answer: "Explain the membrane potential across both mitochondrial membranes.",
            evaluation: "Across the inner membrane [Shelf 2](foreverlm://source/\(shelf[1].id)?t=90) and elsewhere [Found](foreverlm://source/\(elsewhere.id)).",
            score: nil, knowledgeNote: nil, sourceRefs: shelf.map(\.id), answeredAt: talked
        )

        let discussed = try store.chatDiscussionDates(now: now)
        #expect(Set(discussed.keys) == [shelf[1].id, elsewhere.id])
        #expect(discussed[shelf[1].id] == talked)

        let candidates = try store.cohortCandidates(now: now).filter { $0.sourceType != ReviewableChat.sourceType }
        #expect(Set(candidates.map(\.sourceID)) == [shelf[1].id, elsewhere.id])
        // Not a single guaranteed pass for the sources that were only context.
        let selection = CohortSelector.select(candidates: candidates, now: now)
        #expect(Set(selection.spine.map(\.sourceID)) == [shelf[1].id, elsewhere.id])

        // The same shelf, when the learner's own message points at one of them.
        try store.createReviewSession(id: "notebook-chat-2", topic: "One paper", sourceIDs: shelf.map(\.id), startedAt: talked)
        _ = try store.addReviewExchange(
            sessionID: "notebook-chat-2", question: "",
            answer: "Summarise [Shelf 4](foreverlm://source/\(shelf[3].id)) for me.", evaluation: "It says this.",
            score: nil, knowledgeNote: nil, sourceRefs: shelf.map(\.id), answeredAt: talked
        )
        #expect(Set(try store.chatDiscussionDates(now: now).keys) == [shelf[1].id, shelf[3].id, elsewhere.id])
    }

    @Test("A highlight lifts a source one level")
    func annotationLiftsConsumption() throws {
        let store = try KnowledgeStore(inMemory: true)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let marked = try makeSource(store, url: "https://example.com/c18", title: "Marked up")
        _ = try store.recordScheduledSourceActivity(
            sourceID: marked.id, on: now.addingTimeInterval(-86_400), kind: .reading, fraction: 0.4, engagedSeconds: 900
        )
        #expect(try store.cohortCandidates(now: now).isEmpty)
        try store.saveSourceHighlight(
            SourceHighlight(
                id: "h1", sourceID: marked.id, quote: "worth keeping", note: "", color: .yellow,
                anchor: ReaderTextAnchor(exact: "worth keeping"), pdfAnchor: nil, createdAt: now, updatedAt: now
            )
        )
        let candidate = try #require(try store.cohortCandidates(now: now).first)
        #expect(candidate.confidence == .substantial)
        #expect(candidate.engagement.annotationCount == 1)
    }

    @Test("A talk's slides the canvas set down are no annotations: not counted, not in the day's highlights")
    func bareSlideMarksAreNoAnnotations() throws {
        let store = try KnowledgeStore(inMemory: true)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let talk = try makeSource(store, url: "https://example.com/c18b", title: "A talk")
        for slide in 1...3 {
            try store.saveSourceHighlight(ReaderClip.slideHighlight(sourceID: talk.id, slide: slide, title: "Slide \(slide)", pixelWidth: 16, pixelHeight: 9, at: now))
        }
        try store.saveSourceHighlight(ReaderClip.slideHighlight(sourceID: talk.id, slide: 4, title: "Slide 4", pixelWidth: 16, pixelHeight: 9, note: "The key result", at: now))
        #expect(try store.sourceHighlightCount(sourceID: talk.id) == 1)
        let day = try store.sourceHighlights(createdFrom: now.addingTimeInterval(-60), to: now.addingTimeInterval(60), limit: 50)
        #expect(day.count == 1 && day.first?.hasNote == true)
        #expect(try store.sourceHighlights(sourceID: talk.id).count == 4, "the marks are all still kept")
    }

    @Test("The day's ledger counts what was opened, for how long, and what was talked through")
    func ledgerAndTouched() throws {
        let store = try KnowledgeStore(inMemory: true)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let since = MemoryReviewLedger.windowStart(now: now)
        let inWindow = since.addingTimeInterval(3_600)
        let read = try makeSource(store, url: "https://example.com/c19", title: "Read")
        let glanced = try makeSource(store, url: "https://example.com/c20", title: "Glanced")
        let heard = try makeSource(store, url: "https://example.com/c21", title: "Heard")
        let old = try makeSource(store, url: "https://example.com/c22", title: "Old")

        _ = try store.recordScheduledSourceActivity(sourceID: read.id, on: inWindow, kind: .reading, fraction: 0.9, engagedSeconds: 1_200)
        _ = try store.recordScheduledSourceActivity(sourceID: glanced.id, on: inWindow, kind: .reading, fraction: 0.1, engagedSeconds: 40)
        _ = try store.recordScheduledSourceActivity(sourceID: heard.id, on: inWindow, kind: .listening, fraction: 0.5, engagedSeconds: 500)
        _ = try store.recordScheduledSourceActivity(sourceID: old.id, on: since.addingTimeInterval(-3 * 86_400), kind: .reading, fraction: 1, engagedSeconds: 900)
        try store.createReviewSession(id: "chat-3", topic: "About reading", sourceIDs: [read.id], startedAt: inWindow)
        _ = try store.addReviewExchange(
            sessionID: "chat-3", question: "", answer: "So what is it saying?", evaluation: "This.",
            score: nil, knowledgeNote: nil, sourceRefs: [read.id], answeredAt: inWindow
        )

        let rows = try store.engagementRows(since: since, now: now)
        #expect(Set(rows.map(\.sourceID)) == [read.id, glanced.id, heard.id])
        #expect(rows.first { $0.sourceID == heard.id }?.listened == true)
        #expect(rows.first { $0.sourceID == read.id }?.listened == false)

        let chats = try store.chatDiscussionDates(now: now)
        #expect(chats[read.id] == inWindow)

        var ledger = MemoryReviewLedger()
        ledger.sourceCount = rows.count
        ledger.engagedSeconds = rows.reduce(0) { $0 + $1.engagedSeconds }
        ledger.chatDiscussedCount = chats.count
        ledger.listenedCount = rows.filter(\.listened).count
        #expect(ledger.line() == "Yesterday and today: 3 sources · 29m · 1 discussed in chats · 1 listened")
    }

    @Test("A chat the learner had is a candidate of its own; a graded quiz and a thin chat are not")
    func chatsBecomeCandidates() throws {
        let store = try KnowledgeStore(inMemory: true)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let started = now.addingTimeInterval(-3 * 86_400)
        // The exchange's answered_at is what dates the chat; pass it explicitly
        // so the fixed `now` outruns it, the way a real yesterday would.
        let talked = now.addingTimeInterval(-2 * 86_400)
        let long = String(repeating: "Mitophagy through USP30 inhibition clears damaged mitochondria. ", count: 8)

        try store.createReviewSession(id: "chat-a", topic: "Mito Biotechs", sourceIDs: [], startedAt: started)
        _ = try store.addReviewExchange(
            sessionID: "chat-a", question: "", answer: "Which companies edit mtDNA?", evaluation: long,
            score: nil, knowledgeNote: nil, sourceRefs: [], answeredAt: talked
        )
        try store.createReviewSession(id: "quiz-b", topic: "Quiz", sourceIDs: [], startedAt: started)
        _ = try store.addReviewExchange(
            sessionID: "quiz-b", question: "What is mitophagy?", answer: "Clearing mitochondria.", evaluation: long,
            score: 0.7, knowledgeNote: nil, sourceRefs: [], answeredAt: talked
        )
        try store.createReviewSession(id: "thin-c", topic: "Thanks", sourceIDs: [], startedAt: started)
        _ = try store.addReviewExchange(
            sessionID: "thin-c", question: "", answer: "Thanks!", evaluation: "Any time.",
            score: nil, knowledgeNote: nil, sourceRefs: [], answeredAt: talked
        )

        let candidates = try store.cohortCandidates(now: now)
        #expect(candidates.map(\.sourceID) == ["chat-a"])
        let chat = try #require(candidates.first)
        #expect(chat.sourceType == ReviewableChat.sourceType)
        #expect(chat.title == "Mito Biotechs")
        #expect(chat.confidence == .complete)
        #expect(chat.consumedAt == talked)
        #expect(chat.reviewCount == 0)

        // The transcript the ideas come from, and only for the chat that qualifies.
        let transcript = try #require(try store.reviewableChat(sessionID: "chat-a"))
        #expect(transcript.text.hasPrefix("CHAT: Mito Biotechs\n\nYou:\nWhich companies edit mtDNA?\n\nForeverLM:\n"))
        #expect(try store.reviewableChat(sessionID: "quiz-b") == nil)
        #expect(try store.reviewableChat(sessionID: "thin-c") == nil)
        #expect(try store.reviewableChat(sessionID: "missing") == nil)

        // Restricting to sources keeps the chat out unless it is named.
        #expect(try store.cohortCandidates(now: now, restrictToSourceIDs: ["other"]).isEmpty)
        #expect(try store.cohortCandidates(now: now, restrictToSourceIDs: ["chat-a"]).count == 1)
    }

    @Test("Review history rides along with each candidate")
    func candidatesCarryReviewHistory() throws {
        let store = try KnowledgeStore(inMemory: true)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let article = try makeSource(store, url: "https://example.com/c4", title: "Reviewed")
        try store.updateSourceReadAt(sourceID: article.id, readAt: now.addingTimeInterval(-40 * 86_400))

        let sessionID = UUID().uuidString
        try store.createReviewSession(id: sessionID, topic: "Review", sourceIDs: [article.id])
        try store.completeReviewSession(sessionID: sessionID, overallScore: 0.8, summary: "Solid")

        let candidate = try #require(try store.cohortCandidates(now: now).first)
        #expect(candidate.reviewCount == 1)
        #expect(candidate.lastDiscussedAt != nil)
    }

    @Test("A partly-read source is bridgeable but never reviewable on its own")
    func partialReadsAreBridgeableOnly() throws {
        let store = try KnowledgeStore(inMemory: true)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let skimmed = try makeSource(store, url: "https://example.com/c8", title: "Skimmed")
        _ = try store.recordScheduledSourceActivity(
            sourceID: skimmed.id, on: now.addingTimeInterval(-86_400), kind: .reading, fraction: 0.35
        )

        // Absent from the selectable pool that spine and spacing draw from...
        #expect(try store.cohortCandidates(
            now: now,
            minimumConfidence: CohortSelector.selectableConfidence
        ).isEmpty)

        // ...but present in the looser pool bridges draw from. Syntopic reading:
        // the shallow reads still carry context worth colliding with.
        let bridgeable = try store.cohortCandidates(
            now: now,
            minimumConfidence: CohortSelector.bridgeableConfidence
        )
        #expect(bridgeable.map(\.sourceID) == [skimmed.id])
        #expect(bridgeable.first?.confidence == .partial)
    }

    @Test("A barely-opened source is not even bridgeable")
    func trivialEngagementIsNotBridgeable() throws {
        let store = try KnowledgeStore(inMemory: true)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let glanced = try makeSource(store, url: "https://example.com/c9", title: "Glanced")
        _ = try store.recordScheduledSourceActivity(
            sourceID: glanced.id, on: now.addingTimeInterval(-86_400), kind: .reading, fraction: 0.05
        )
        #expect(try store.cohortCandidates(
            now: now,
            minimumConfidence: CohortSelector.bridgeableConfidence
        ).isEmpty)
    }

    @Test("A source dated in the future cannot jump the queue")
    func futureDatesAreRejected() throws {
        let store = try KnowledgeStore(inMemory: true)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let article = try makeSource(store, url: "https://example.com/c5", title: "Future")
        try store.updateSourceReadAt(sourceID: article.id, readAt: now.addingTimeInterval(86_400))
        #expect(try store.cohortCandidates(now: now).isEmpty)
    }

    @Test("Exemplar questions come only from well-answered exchanges about that source")
    func exemplarQuestionsAreScoped() throws {
        let store = try KnowledgeStore(inMemory: true)
        let article = try makeSource(store, url: "https://example.com/c6", title: "Exemplars")
        let other = try makeSource(store, url: "https://example.com/c7", title: "Other")

        let sessionID = UUID().uuidString
        try store.createReviewSession(id: sessionID, topic: "T", sourceIDs: [article.id, other.id])
        _ = try store.addReviewExchange(
            sessionID: sessionID,
            question: "Strong question about this source",
            answer: "answer", evaluation: "good", score: 0.9,
            knowledgeNote: nil, sourceRefs: [article.id]
        )
        _ = try store.addReviewExchange(
            sessionID: sessionID,
            question: "Weak answer question",
            answer: "answer", evaluation: "poor", score: 0.2,
            knowledgeNote: nil, sourceRefs: [article.id]
        )
        _ = try store.addReviewExchange(
            sessionID: sessionID,
            question: "Question about the other source",
            answer: "answer", evaluation: "good", score: 0.95,
            knowledgeNote: nil, sourceRefs: [other.id]
        )

        let exemplars = try store.exemplarQuestions(sourceID: article.id)
        #expect(exemplars == ["Strong question about this source"])
    }
}
