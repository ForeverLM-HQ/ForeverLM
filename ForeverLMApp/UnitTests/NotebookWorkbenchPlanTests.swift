import Testing
import Foundation
@testable import ForeverLM

#if os(macOS)

@Suite("Notebook Workbench Plan")
struct NotebookWorkbenchPlanTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @MainActor @Test func remoteMemoryEntitiesRefreshTheCompanionQueue() {
        #expect(StudioViewModel.cloudKitEntitiesRequireMemoryRefresh([.memoryItem]))
        #expect(StudioViewModel.cloudKitEntitiesRequireMemoryRefresh([.memoryAttempt]))
        #expect(StudioViewModel.cloudKitEntitiesRequireMemoryRefresh([.source]))
        #expect(StudioViewModel.cloudKitEntitiesRequireMemoryRefresh([.reviewSession]))
        #expect(!StudioViewModel.cloudKitEntitiesRequireMemoryRefresh([.preference]))
    }

    @MainActor @Test func immutableSyncConflictsAreExplainedWithoutClaimingSuccess() {
        let single = StudioViewModel.cloudKitSyncConflictToast(
            entity: .memoryItem,
            reason: "The source-grounded rubric differs.",
            count: 1
        )
        #expect(single.contains("Cloud sync stopped"))
        #expect(single.contains("memory idea"))
        #expect(single.contains("local copy is intact"))
        #expect(!single.localizedCaseInsensitiveContains("synced successfully"))

        let multiple = StudioViewModel.cloudKitSyncConflictToast(
            entity: .memoryAttempt,
            reason: "Immutable attempts disagree.",
            count: 3
        )
        #expect(multiple.contains("3 learning records"))
        #expect(multiple.contains("local copies are intact"))

        let malformedWebImport = StudioViewModel.cloudKitSyncConflictToast(
            entity: .source,
            reason: CloudKitInboundWebPDFRetry.quarantineReasonPrefix
                + "CloudKit web PDF is unreadable.",
            count: 1
        )
        #expect(malformedWebImport.contains("unreadable Web Studio file"))
        #expect(malformedWebImport.contains("local library is intact"))
        #expect(!malformedWebImport.contains("immutable evidence"))
        #expect(!malformedWebImport.contains("devices disagree"))

        // A refused save is not something the learner can resolve, so it must
        // not borrow the conflict wording that asks them to.
        let refusedSave = StudioViewModel.cloudKitSyncConflictToast(
            entity: .artifact,
            reason: CloudKitRejectedSaveQuarantine.encodedReason(
                errorCode: 12,
                message: "Cannot create new type Artifact in production schema"
            ),
            count: 2
        )
        #expect(refusedSave.contains("iCloud refused 2 records"))
        #expect(refusedSave.contains("retries"))
        #expect(refusedSave.contains("production schema"))
        #expect(!refusedSave.contains("devices disagree"))
    }

    private func companionGoal(
        items: [LearningGoalItem],
        gaps: [LearningGoalGap]? = nil
    ) -> LearningGoalRecord {
        LearningGoalRecord(
            id: "goal-1",
            title: "Test Notebook",
            startAt: now,
            endAt: LearningGoalRecord.openEndedEndAt,
            createdAt: now,
            updatedAt: now,
            status: "active",
            items: items,
            kind: LearningGoalRecord.companionKind,
            gaps: gaps
        )
    }

    private func approvedItem(
        sourceID: String,
        quizCount: Int? = nil,
        lastScore: Double? = nil,
        completed: Bool = false
    ) -> LearningGoalItem {
        LearningGoalItem(
            id: "item-\(sourceID)",
            goalID: "goal-1",
            sourceID: sourceID,
            addedAt: now,
            completedAt: completed ? now : nil,
            reviewState: LearningGoalItemReviewState.approved.rawValue,
            quizCount: quizCount,
            lastScore: lastScore
        )
    }

    private func memoryItem(
        _ id: String,
        sourceIDs: [String],
        learnerContext: String? = nil
    ) -> MemoryItem {
        let anchors = sourceIDs.enumerated().map { index, sourceID in
            MemoryItemSource(
                id: "anchor-\(id)-\(index)",
                memoryItemID: id,
                sourceID: sourceID,
                excerpt: "Grounded evidence for \(id) from \(sourceID).",
                sourceSHA256: "hash-\(sourceID)",
                sortIndex: index
            )
        }
        return MemoryItem(
            id: id,
            kind: .concept,
            target: "Understand \(id)",
            rubricJSON: #"{"criteria":["Explain the mechanism"]}"#,
            learnerContext: learnerContext,
            sources: anchors,
            createdAt: now,
            updatedAt: now
        )
    }

    private func dueMemory(
        _ id: String,
        sourceIDs: [String]? = nil,
        dueOffset: TimeInterval = -86_400,
        difficulty: Double = 0.5,
        lapseCount: Int = 0,
        learnerContext: String? = nil
    ) -> DueMemoryItem {
        let item = memoryItem(
            id,
            sourceIDs: sourceIDs ?? ["source-\(id)"],
            learnerContext: learnerContext
        )
        return DueMemoryItem(
            item: item,
            schedule: MemorySchedule(
                memoryItemID: id,
                dueAt: now.addingTimeInterval(dueOffset),
                difficulty: difficulty,
                lapseCount: lapseCount
            ),
            daysOverdue: max(0, Int(-dueOffset / 86_400))
        )
    }

    private func firstReview(_ sourceID: String) -> MemoryReviewNewItem {
        MemoryReviewNewItem(
            sourceID: sourceID,
            title: sourceID,
            sourceType: "article",
            consumedAt: now.addingTimeInterval(-172_800),
            dueAt: now.addingTimeInterval(-86_400),
            daysOverdue: 1
        )
    }

    @Test("groups sources by derived understanding state")
    func understandingGroups() {
        let goal = companionGoal(items: [
            approvedItem(sourceID: "a"),
            approvedItem(sourceID: "b", quizCount: 1),
            approvedItem(sourceID: "c", lastScore: 0.85),
            approvedItem(sourceID: "d", completed: true),
        ])
        let plan = NotebookWorkbenchPlan(goal: goal)

        #expect(plan.toRead.map(\.sourceID) == ["a"])
        #expect(plan.reading.map(\.sourceID) == ["b"])
        #expect(plan.understood.map(\.sourceID) == ["c", "d"])
        #expect(plan.masteredCount == 2)
        #expect(plan.approvedCount == 4)
    }

    @Test("next suggestion prefers open question tied to a source")
    func nextFromTiedQuestion() {
        let gap = LearningGoalGap(
            id: "gap-1",
            goalID: "goal-1",
            summary: "How does X relate to Y?",
            sourceID: "paper-b",
            status: "open",
            severity: 0.9,
            firstSeenAt: now,
            lastSeenAt: now,
            resolvedAt: nil,
            sessionID: nil
        )
        let goal = companionGoal(
            items: [
                approvedItem(sourceID: "paper-a"),
                approvedItem(sourceID: "paper-b"),
            ],
            gaps: [gap]
        )
        let plan = NotebookWorkbenchPlan(goal: goal)

        #expect(plan.next?.sourceIDs == ["paper-b"])
        #expect(plan.next?.tiedQuestionID == "gap-1")
        #expect(plan.next?.reason == gap.summary)
    }

    @Test("next suggestion prefers review-due source")
    func nextFromReviewDue() {
        let goal = companionGoal(items: [
            approvedItem(sourceID: "a", quizCount: 2, lastScore: 0.6),
            approvedItem(sourceID: "b"),
        ])
        let plan = NotebookWorkbenchPlan(goal: goal, reviewDueSourceIDs: ["a"])

        #expect(plan.next?.sourceIDs == ["a"])
        #expect(plan.next?.reason.contains("Spaced review") == true)
    }

    @Test("daily quiz blend matches approved pool pacing")
    func companionCardPlanBlend() {
        let goal = companionGoal(items: [
            approvedItem(sourceID: "new-a"),
            approvedItem(sourceID: "new-b"),
            approvedItem(sourceID: "rev-a", quizCount: 1, lastScore: 0.5),
        ])
        let plan = CompanionCardPlan(goal: goal)

        #expect(plan.newToday >= 1)
        #expect(plan.todaysItems.count == plan.newToday + plan.reviewToday)
        #expect(plan.todaysItems.contains { $0.item.sourceID == "new-a" && !$0.isReview })
    }

    @Test("daily review plan prioritizes gap-linked source")
    func dailyReviewPlanGapPriority() {
        let gap = LearningGoalGap(
            id: "gap-1",
            goalID: "goal-1",
            summary: "Mechanism unclear",
            sourceID: "paper-b",
            status: "open",
            severity: 0.9,
            firstSeenAt: now,
            lastSeenAt: now,
            resolvedAt: nil,
            sessionID: nil
        )
        let goal = companionGoal(
            items: [
                approvedItem(sourceID: "paper-a"),
                approvedItem(sourceID: "paper-b"),
            ],
            gaps: [gap]
        )
        let plan = DailyReviewPlan.assemble(
            goal: goal,
            memoryDue: [],
            readingInProgressSourceIDs: []
        )

        #expect(plan?.sourceIDs.first == "paper-b")
        #expect(plan?.items.first?.role == .gap)
    }

    @Test("daily review plan dedupes and caps at daily target")
    func dailyReviewPlanCap() {
        var goal = companionGoal(items: (0..<6).map { approvedItem(sourceID: "s-\($0)") })
        goal = LearningGoalRecord(
            id: goal.id,
            title: goal.title,
            startAt: goal.startAt,
            endAt: goal.endAt,
            createdAt: goal.createdAt,
            updatedAt: goal.updatedAt,
            status: goal.status,
            items: goal.items,
            kind: goal.kind,
            dailyTarget: 2,
            gaps: goal.gaps
        )
        let plan = DailyReviewPlan.assemble(
            goal: goal,
            memoryDue: [],
            readingInProgressSourceIDs: Set(["s-0", "s-1", "s-2"])
        )

        #expect(plan?.sourceIDs.count == 2)
        #expect(Set(plan?.sourceIDs ?? []).count == 2)
    }

    @Test("memory companion puts unresolved struggles before ordinary due items")
    func memoryCompanionStruggleFirst() {
        let plan = MemoryCompanionPlan.assemble(
            dueItems: [
                dueMemory("older", dueOffset: -432_000),
                dueMemory("struggle", dueOffset: -86_400, learnerContext: "Confuses cause and effect"),
            ],
            firstReviews: [],
            availableSourceIDs: ["source-older", "source-struggle"],
            now: now
        )

        #expect(plan?.targets.map(\.memoryItemID) == ["struggle", "older"])
        #expect(plan?.targets.first?.reason == .struggle)
    }

    @Test("memory companion reserves one first-review slot behind due work")
    func memoryCompanionReservesIntakeSlot() {
        let due = (0..<4).map { dueMemory("due-\($0)", dueOffset: TimeInterval(-($0 + 1) * 86_400)) }
        let available = Set(due.flatMap { $0.item.sources.map(\.sourceID) } + ["fresh"])
        let plan = MemoryCompanionPlan.assemble(
            dueItems: due,
            firstReviews: [firstReview("fresh")],
            availableSourceIDs: available,
            limit: 3,
            now: now
        )

        #expect(plan?.targets.count == 3)
        #expect(plan?.targets.filter { $0.reason == .firstReview }.map(\.sourceID) == ["fresh"])
    }

    @Test("memory companion does not intake a source already represented by a memory")
    func memoryCompanionDedupesIntakeAgainstExistingMemory() {
        let plan = MemoryCompanionPlan.assemble(
            dueItems: [dueMemory("existing", sourceIDs: ["same-source"])],
            firstReviews: [firstReview("same-source")],
            availableSourceIDs: ["same-source"],
            now: now
        )

        #expect(plan?.targets.count == 1)
        #expect(plan?.targets.first?.memoryItemID == "existing")
    }

    @Test("memory companion omits memories whose anchors are unavailable")
    func memoryCompanionRequiresAvailableAnchor() {
        let noAnchors = dueMemory("no-anchor", sourceIDs: [])
        let unavailable = dueMemory("unavailable", sourceIDs: ["missing-source"])
        let plan = MemoryCompanionPlan.assemble(
            dueItems: [noAnchors, unavailable],
            firstReviews: [],
            availableSourceIDs: [],
            now: now
        )

        #expect(plan == nil)
    }

    @Test("memory companion source IDs keep stable order and remove duplicates")
    func memoryCompanionSourceIDsAreStableAndUnique() {
        let multi = dueMemory("multi", sourceIDs: ["a", "b"])
        let overlap = dueMemory("overlap", sourceIDs: ["b", "c"])
        let plan = MemoryCompanionPlan.assemble(
            dueItems: [multi, overlap],
            firstReviews: [],
            availableSourceIDs: ["a", "b", "c"],
            now: now
        )

        #expect(plan?.sourceIDs == ["a", "b", "c"])
    }
}

@Suite("Notebook source recommendations")
struct NotebookSourceRecommendationTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func item(_ sourceID: String, state: LearningGoalItemReviewState) -> LearningGoalItem {
        LearningGoalItem(
            id: "item-\(sourceID)",
            goalID: "notebook",
            sourceID: sourceID,
            addedAt: now,
            reviewState: state.rawValue
        )
    }

    private func article(_ id: String, title: String) -> StudioArticle {
        StudioArticle(url: "https://example.com/\(id)", title: title, id: id)
    }

    private func goal(
        id: String = "notebook",
        title: String = "Mito Phenotyping",
        status: String = LearningGoalStatus.active.rawValue,
        items: [LearningGoalItem] = [],
        description: String? = nil,
        topic: String? = nil,
        gaps: [LearningGoalGap]? = nil,
        notes: String? = nil,
        parentNotebookID: String? = nil,
        researchQuestions: [String]? = nil
    ) -> LearningGoalRecord {
        LearningGoalRecord(
            id: id,
            title: title,
            startAt: now,
            endAt: LearningGoalRecord.openEndedEndAt,
            createdAt: now,
            updatedAt: now,
            status: status,
            items: items,
            kind: LearningGoalRecord.companionKind,
            description: description,
            topic: topic,
            gaps: gaps,
            notes: notes,
            parentNotebookID: parentNotebookID,
            researchQuestions: researchQuestions
        )
    }

    @Test("seed includes defining Notebook context and only approved source titles")
    func includesNotebookContext() {
        let openGap = LearningGoalGap(
            id: "open-gap",
            goalID: "notebook",
            summary: "Which assays predict clinical translation?",
            sourceID: "approved",
            status: "open",
            severity: 0.9,
            firstSeenAt: now,
            lastSeenAt: now,
            resolvedAt: nil,
            sessionID: nil
        )
        let resolvedGap = LearningGoalGap(
            id: "resolved-gap",
            goalID: "notebook",
            summary: "This resolved gap must not steer recommendations",
            sourceID: nil,
            status: "resolved",
            severity: 1,
            firstSeenAt: now,
            lastSeenAt: now,
            resolvedAt: now,
            sessionID: nil
        )
        let notebook = goal(
            items: [
                item("approved", state: .approved),
                item("pending", state: .pending),
                item("rejected", state: .rejected),
            ],
            description: "Prioritize translational biomarkers over basic morphology.",
            topic: "Mitochondrial function in drug discovery",
            gaps: [resolvedGap, openGap],
            notes: "Respiration and membrane potential appear complementary.",
            researchQuestions: ["Which phenotypes best predict drug response?"]
        )
        let activeGoal = goal(
            id: "active-goal",
            title: "Benchmark perturbation assays",
            parentNotebookID: notebook.id
        )
        let archivedGoal = goal(
            id: "archived-goal",
            title: "Archived unrelated work",
            status: LearningGoalStatus.archived.rawValue,
            parentNotebookID: notebook.id
        )
        let articles = [
            "approved": article("approved", title: "Single-cell mitochondrial stress signatures"),
            "pending": article("pending", title: "Pending suggestion must not steer results"),
            "rejected": article("rejected", title: "Rejected suggestion must not steer results"),
        ]

        let seed = notebookSourceRecommendationSeed(
            goal: notebook,
            childGoals: [activeGoal, archivedGoal],
            articlesById: articles
        )

        #expect(seed.embeddingText.contains("Research questions: Which phenotypes best predict drug response?"))
        #expect(seed.embeddingText.contains("Existing sources: Single-cell mitochondrial stress signatures"))
        #expect(seed.embeddingText.contains("Instructions: Prioritize translational biomarkers"))
        #expect(seed.embeddingText.contains("Goals: Benchmark perturbation assays"))
        #expect(seed.embeddingText.contains("Open questions: Which assays predict clinical translation?"))
        #expect(seed.embeddingText.contains("Synthesis: Respiration and membrane potential"))
        #expect(!seed.embeddingText.contains("Pending suggestion"))
        #expect(!seed.embeddingText.contains("Rejected suggestion"))
        #expect(!seed.embeddingText.contains("Archived unrelated work"))
        #expect(!seed.embeddingText.contains("resolved gap"))
    }

    @Test("source titles are sampled across a large Notebook and seed stays compact")
    func samplesAcrossPoolWithinEmbeddingBudget() {
        let items = (0..<16).map { item("source-\($0)", state: .approved) }
        let articles = Dictionary(uniqueKeysWithValues: (0..<16).map {
            ("source-\($0)", article("source-\($0)", title: "marker\($0) mechanism"))
        })
        let longText = Array(repeating: "context", count: 200).joined(separator: " ")
        let notebook = goal(
            items: items,
            description: longText,
            topic: longText,
            notes: longText,
            researchQuestions: [longText]
        )

        let seed = notebookSourceRecommendationSeed(
            goal: notebook,
            childGoals: [],
            articlesById: articles
        )

        #expect(seed.embeddingText.contains("marker0"))
        #expect(seed.embeddingText.contains("marker14"))
        #expect(!seed.embeddingText.contains("marker1 mechanism"))
        #expect(seed.embeddingText.split(whereSeparator: { $0.isWhitespace }).count <= 120)
    }

    /// The lexical branch ranks by how many exact terms a source matches, so the
    /// vocabulary of the sources a Notebook already holds must not become the terms it
    /// searches by — that is what let a Notebook named for a gene symbol rank papers
    /// naming that symbol below papers sharing a word with its existing pool.
    @Test("lexical query carries the Notebook's subject, not its existing pool")
    func lexicalQueryExcludesPoolVocabulary() {
        let notebook = goal(
            items: [item("approved", state: .approved)],
            description: "Prioritize translational biomarkers over basic morphology.",
            topic: "GDF15",
            notes: "Respiration and membrane potential appear complementary.",
            researchQuestions: ["Why is GDF15 a good biomarker of aging?"]
        )
        let childGoal = goal(
            id: "active-goal",
            title: "Benchmark perturbation assays",
            parentNotebookID: notebook.id
        )
        let articles = [
            "approved": article("approved", title: "Psychobiological regulation of saliva cf-mtDNA"),
        ]

        let seed = notebookSourceRecommendationSeed(
            goal: notebook,
            childGoals: [childGoal],
            articlesById: articles
        )

        #expect(seed.lexicalQuery.contains("GDF15"))
        #expect(seed.lexicalQuery.contains("Why is GDF15 a good biomarker of aging?"))
        #expect(seed.lexicalQuery.contains("Prioritize translational biomarkers"))
        #expect(seed.lexicalQuery.contains("Benchmark perturbation assays"))
        // Present in the embedding text, deliberately absent here.
        #expect(!seed.lexicalQuery.contains("Psychobiological"))
        #expect(!seed.lexicalQuery.contains("membrane potential"))
        #expect(seed.embeddingText.contains("Psychobiological"))
        #expect(seed.embeddingText.contains("membrane potential"))
        // Section labels would themselves become search terms.
        #expect(!seed.lexicalQuery.contains("Research questions:"))
    }
}

#endif

@Suite("CloudKit: what a launch announces")
struct CloudKitConflictLaunchToastTests {
    @Test("A refusal the engine's start re-arms is not announced at launch; a conflict that needs the learner still is")
    func launchSkipsWhatStartRetries() {
        let refusedSave = CloudKitRejectedSaveQuarantine.encodedReason(
            errorCode: 12,
            message: "Cannot create or modify field 'payloadAsset' in record 'ReviewSession' in production schema"
        )
        let refusedDelete = CloudKitRejectedChangeQuarantine.encodedReason(operation: .delete, errorCode: 12, message: "refused")
        #expect(StudioViewModel.isRearmedAtEngineStart(reason: refusedSave))
        #expect(StudioViewModel.isRearmedAtEngineStart(reason: refusedDelete))
        #expect(!StudioViewModel.isRearmedAtEngineStart(reason: "Both sides changed the same passage."))
        #expect(!StudioViewModel.isRearmedAtEngineStart(reason: CloudKitInboundWebPDFRetry.quarantineReasonPrefix + " unreadable"))
    }
}
