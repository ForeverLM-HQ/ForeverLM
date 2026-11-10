import Foundation
import SQLite3
import Testing
@testable import ForeverLM

/// Step 2 of docs/memory-design.md: ideas as the unit of memory, the contour
/// grade, the steer, the depth, and the coverage-driven ladder. The pure
/// pieces are pinned first; the store tests then prove schema 89 round-trips
/// each of them and that the ladder reads what the grade wrote.
@Suite("Memory ideas")
struct MemoryIdeasTests {

    @Test("An idea id names its source, its text generation, and its place")
    func ideaIdentity() {
        let id = SourceIdea.id(sourceID: "src-1", contentHash: "abcdef0123456789ffff", index: 3)
        #expect(id == "src-1::idea::abcdef012345::3")
        #expect(SourceIdea.sourceID(fromIdeaID: id) == "src-1")
        #expect(SourceIdea.sourceID(fromIdeaID: "not-an-idea") == nil)
        #expect(SourceIdea.sourceID(fromIdeaID: "::idea::x::0") == nil)
    }

    @Test("Produced counts whole, partial half, missing nothing")
    func producedFraction() {
        let coverage = [
            MemoryIdeaCoverage(ideaID: "a", status: .produced),
            MemoryIdeaCoverage(ideaID: "b", status: .partial),
            MemoryIdeaCoverage(ideaID: "c", status: .missing),
            MemoryIdeaCoverage(ideaID: "d", status: .produced),
        ]
        #expect(MemoryIdeaCoverage.producedFraction(coverage) == 0.625)
        #expect(MemoryIdeaCoverage.producedFraction([]) == 0)
        let json = MemoryIdeaCoverage.encode(coverage)
        #expect(json?.contains("\"idea_id\"") == true)
        #expect(MemoryIdeaCoverage.decode(json) == coverage)
        #expect(MemoryIdeaCoverage.decode("not json").isEmpty)
    }

    @Test("The ladder climbs on a good recall, holds on a poor one, skips after two near-complete ones")
    func ladder() {
        #expect(ForeverLMCore.memoryReviewRung(producedFractions: []) == 0)
        #expect(ForeverLMCore.memoryReviewRung(producedFractions: [0.4]) == 0)
        #expect(ForeverLMCore.memoryReviewRung(producedFractions: [0.7]) == 1)
        #expect(ForeverLMCore.memoryReviewRung(producedFractions: [0.7, 0.3]) == 1)
        // Two near-complete recalls in a row skip a rung: 1, then +2.
        #expect(ForeverLMCore.memoryReviewRung(producedFractions: [0.95, 0.9]) == 3)
        // An ambiguous question moves nothing and breaks the skip streak.
        #expect(ForeverLMCore.memoryReviewRung(producedFractions: [0.95, nil, 0.9]) == 2)
        // Capped at the ladder's top.
        let many = Array(repeating: Optional(1.0), count: 40)
        #expect(ForeverLMCore.memoryReviewRung(producedFractions: many) == ForeverLMCore.memoryReviewLadderDays.count - 1)
        #expect(ForeverLMCore.memoryReviewIntervalDays(rung: 0) == 1)
        #expect(ForeverLMCore.memoryReviewIntervalDays(rung: 2) == 7)
        #expect(ForeverLMCore.memoryReviewIntervalDays(rung: 99) == 180)
        // The selector reads the same ladder.
        #expect(CohortSelector.intervals == ForeverLMCore.memoryReviewLadderDays)
        #expect(CohortSelector.interval(forReviewCount: 1) == 3)
    }

    @Test("A candidate with a graded contour is measured by its rung, not its discussion count")
    func candidateRung() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var candidate = CohortCandidate(
            sourceID: "s",
            title: "S",
            sourceType: "paper",
            consumedAt: now.addingTimeInterval(-30 * 86_400),
            confidence: .substantial,
            reviewCount: 4,
            lastDiscussedAt: now.addingTimeInterval(-5 * 86_400)
        )
        #expect(CohortSelector.interval(for: candidate) == 60)
        candidate.contourRung = 1
        #expect(CohortSelector.interval(for: candidate) == 3)
        // Five days since a source on rung 1 (3 days) is due; on rung 4 it is not.
        let due = CohortSelector.select(candidates: [candidate], now: now)
        #expect(due.spacing.map(\.sourceID) == ["s"])
    }

    private static let ideas = [
        SourceIdea(id: "src::idea::h::0", sourceID: "src", statement: "One", recallNote: "", contentHash: "h", sortIndex: 0),
        SourceIdea(id: "src::idea::h::1", sourceID: "src", statement: "Two", recallNote: "", contentHash: "h", sortIndex: 1),
    ]

    @Test("A grade must name every idea of its source, exactly once, and nothing foreign")
    func gradeValidation() {
        let ideasBySource = ["src": Self.ideas]
        func validate(_ arguments: [String: Any]) -> Result<MemoryContourGrade, MemoryContourGrade.ValidationError> {
            MemoryContourGrade.validate(arguments: arguments, ideasBySource: ideasBySource)
        }
        let good: [String: Any] = [
            "source_id": "src",
            "score": 0.8,
            "idea_coverage": [
                ["idea_id": "src::idea::h::1", "status": "missing"],
                ["idea_id": "src::idea::h::0", "status": "PRODUCED"],
            ],
        ]
        guard case .success(let grade) = validate(good) else {
            Issue.record("a complete grade was refused")
            return
        }
        #expect(grade.sourceID == "src")
        // Stored in the source's idea order regardless of how the model listed them.
        #expect(grade.coverage.map(\.ideaID) == ["src::idea::h::0", "src::idea::h::1"])
        #expect(grade.verdict == .sound)
        #expect(grade.operation == .recall)
        #expect(grade.producedFractionForLadder == 0.5)
        #expect(grade.missingIdeaIDs == ["src::idea::h::1"])

        #expect(validate(["score": 0.5, "idea_coverage": []]) == .failure(.missingSource))
        #expect(validate(["source_id": "other", "score": 0.5]) == .failure(.unknownSource("other")))
        var incomplete = good
        incomplete["idea_coverage"] = [["idea_id": "src::idea::h::0", "status": "produced"]]
        #expect(validate(incomplete) == .failure(.incompleteCoverage(["src::idea::h::1"])))
        var foreign = good
        foreign["idea_coverage"] = [
            ["idea_id": "src::idea::h::0", "status": "produced"],
            ["idea_id": "elsewhere::idea::h::0", "status": "produced"],
        ]
        #expect(validate(foreign) == .failure(.foreignIdea("elsewhere::idea::h::0")))
        var duplicate = good
        duplicate["idea_coverage"] = [
            ["idea_id": "src::idea::h::0", "status": "produced"],
            ["idea_id": "src::idea::h::0", "status": "missing"],
        ]
        #expect(validate(duplicate) == .failure(.duplicateIdea("src::idea::h::0")))
        var badScore = good
        badScore["score"] = 1.5
        #expect(validate(badScore) == .failure(.badScore(received: "the number 1.5")))
        badScore["score"] = NSNull()
        #expect(validate(badScore) == .failure(.badScore(received: "null")))
        badScore["score"] = true
        #expect(validate(badScore) == .failure(.badScore(received: "the boolean true")))
        badScore["score"] = "0.5"
        #expect(validate(badScore) == .failure(.badScore(received: "the string \"0.5\"")))
        // JSON delivers 0 and 1 as NSNumbers that bridge to Bool on Darwin; a
        // blank answer (0) and a perfect one (1) are both real grades.
        for literal in ["0", "1", "0.0", "1.0"] {
            let json = #"{"source_id":"src","score":\#(literal),"idea_coverage":[{"idea_id":"src::idea::h::0","status":"missing"},{"idea_id":"src::idea::h::1","status":"missing"}]}"#
            let parsed = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
            guard case .success(let graded) = validate(parsed) else {
                Issue.record("a JSON score of \(literal) was refused")
                continue
            }
            #expect(graded.score == Double(literal))
        }
        var ambiguous = good
        ambiguous["question_verdict"] = "ambiguous"
        ambiguous["operation"] = "contrast"
        guard case .success(let blamed) = validate(ambiguous) else {
            Issue.record("an ambiguous verdict was refused")
            return
        }
        #expect(blamed.verdict == .ambiguous)
        #expect(blamed.operation == .contrast)
        #expect(blamed.producedFractionForLadder == nil)
    }

    @Test("Drafts get deterministic ids and are wanted where they overlap a highlight")
    func draftsBecomeIdeas() {
        let quote = "Mitochondria are transferred between cells along tunnelling nanotubes."
        let highlight = SourceHighlight(
            id: "hl-1",
            sourceID: "src",
            quote: quote,
            note: "",
            color: .yellow,
            anchor: ReaderTextAnchor(exact: quote),
            pdfAnchor: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        let drafts = [
            SourceIdeaDraft(
                statement: "Cells hand whole mitochondria to neighbours through nanotubes.",
                recallNote: "nanotubes; whole organelles; neighbour cells",
                anchors: ["mitochondria are transferred between cells along tunnelling nanotubes"]
            ),
            SourceIdeaDraft(statement: "Cells hand whole mitochondria to neighbours through nanotubes.", recallNote: "", anchors: []),
            SourceIdeaDraft(statement: "Transplanted mitochondria restore respiration in the recipient.", recallNote: "", anchors: ["short"]),
            SourceIdeaDraft(statement: "   ", recallNote: "", anchors: []),
        ]
        let ideas = SourceIdeaExtractionService.ideas(
            from: drafts,
            sourceID: "src",
            contentHash: "0123456789abcdefXYZ",
            highlights: [highlight]
        )
        #expect(ideas.count == 2)
        #expect(ideas[0].id == "src::idea::0123456789ab::0")
        #expect(ideas[1].id == "src::idea::0123456789ab::1")
        #expect(ideas[0].wanted)
        #expect(ideas[0].anchors.first?.highlightID == "hl-1")
        #expect(!ideas[1].wanted)
        #expect(ideas[1].anchors.first?.highlightID == nil)
        #expect(ideas.allSatisfy { $0.contentHash == "0123456789abcdefXYZ" && $0.status == .active })
    }

    @Test("Idea extraction reads the whole text: one request when the window takes it, else parts that are the text and each fit untrimmed")
    func extractionReadsTheWholeText() throws {
        // The request carries every character it is given; until 2026-09-30
        // it stopped at 240,000 while the ideas named the whole text's hash.
        let long = String(repeating: "Mitochondria divide by fission at ER contact sites. ", count: 6_000) + "THE LAST WORDS."
        #expect(long.count > 240_000)
        let message = SourceIdeaDrafting.userMessage(title: "Long", sourceType: "book", highlightLines: [], sourceText: long)
        #expect(message.hasSuffix(long))

        let system = Prompts.sourceIdeaExtraction
        let highlights = ["Fission needs Drp1 at the contact site."]
        func parts(_ text: String, budget: Int?) throws -> [String] {
            try AIService.sourceIdeaTextParts(
                title: "Long", sourceType: "book", highlightLines: highlights,
                sourceText: text, system: system, inputBudget: budget
            )
        }
        // No published window: one request, the whole text.
        #expect(try parts(long, budget: nil) == [long])
        // A window that takes it whole: one request.
        #expect(try parts(long, budget: system.count + long.count * 2) == [long])

        // An 8k-token model: consecutive parts, together exactly the text, each
        // request one the budgeter sends as it is.
        let provider = AIProvider.cerebras
        let model = "llama3.1-8b"
        let budget = try #require(AIService.inputCharacterBudget(
            provider: provider, model: model, requestedMaxTokens: AIService.sourceIdeaExtractionMaxTokens
        ))
        let text = String(long.suffix(80_000))
        let split = try parts(text, budget: budget)
        #expect(split.count > 1)
        #expect(split.joined() == text)
        for (index, part) in split.enumerated() {
            let user = SourceIdeaDrafting.userMessage(
                title: "Long", sourceType: "book", highlightLines: highlights,
                sourceText: part, part: SourceIdeaDrafting.Part(index: index, count: split.count)
            )
            #expect(user.contains("PART \(index + 1) OF \(split.count)"))
            let budgeted = AIService.budgetedOneShotRequest(
                provider: provider, model: model, system: system, user: user,
                requestedMaxTokens: AIService.sourceIdeaExtractionMaxTokens
            )
            #expect(budgeted.system == system && budgeted.user == user, "part \(index + 1) would be trimmed")
        }
        #expect(split.dropLast().allSatisfy { $0.hasSuffix(" ") }, "a part ends between words")

        // Instructions the window cannot take are refused, never cut.
        #expect(throws: AIError.self) {
            try AIService.sourceIdeaTextParts(
                title: "Long", sourceType: "book", highlightLines: [],
                sourceText: text, system: system, inputBudget: system.count / 2
            )
        }
    }

    @Test("A text splits at paragraph breaks, then line breaks, then the budget, and the parts are exactly the text")
    func sourceTextParts() {
        let paragraphs = (1...40)
            .map { "Paragraph \($0) says one thing about cristae.\nIt has a second line." }
            .joined(separator: "\n\n")
        let parts = SourceIdeaDrafting.sourceTextParts(paragraphs, characterBudget: 300)
        #expect(parts.count > 1)
        #expect(parts.joined() == paragraphs)
        #expect(parts.allSatisfy { $0.count <= 300 })
        #expect(parts.dropLast().allSatisfy { $0.hasSuffix("\n\n") })
        #expect(SourceIdeaDrafting.sourceTextParts(paragraphs, characterBudget: nil) == [paragraphs])
        #expect(SourceIdeaDrafting.sourceTextParts(paragraphs, characterBudget: paragraphs.count) == [paragraphs])

        // A Windows line break is one character and is never split.
        let lines = (1...50).map { "Line \($0) of a Windows file." }.joined(separator: "\r\n")
        let lineParts = SourceIdeaDrafting.sourceTextParts(lines, characterBudget: 120)
        #expect(lineParts.joined() == lines)
        #expect(lineParts.dropLast().allSatisfy { $0.hasSuffix("\r\n") })

        // No break anywhere: cut at the budget, nothing lost.
        let unbroken = String(repeating: "a", count: 1_000)
        let cut = SourceIdeaDrafting.sourceTextParts(unbroken, characterBudget: 300)
        #expect(cut.map(\.count) == [300, 300, 300, 100])
        #expect(cut.joined() == unbroken)
    }

    @Test("Drafts of a source read in parts keep source order, count a repeated statement once, and share the limit between the parts")
    func mergedPartDrafts() {
        func drafts(_ prefix: String, _ count: Int) -> [SourceIdeaDraft] {
            (1...count).map { SourceIdeaDraft(statement: "\(prefix) idea \($0) about the inner membrane.", recallNote: "", anchors: []) }
        }
        let opening = drafts("Opening", 10)
        let ending = drafts("Ending", 10)
        #expect(SourceIdeaDrafting.mergedDrafts([opening]) == opening)
        #expect(SourceIdeaDrafting.mergedDrafts([Array(opening.prefix(3)), Array(ending.prefix(2))])
            == Array(opening.prefix(3)) + Array(ending.prefix(2)))

        let merged = SourceIdeaDrafting.mergedDrafts([opening, ending])
        #expect(merged.count == SourceIdea.maximumPerSource)
        let share = SourceIdea.maximumPerSource / 2
        #expect(merged == Array(opening.prefix(share)) + Array(ending.prefix(share)), "the ending is heard as well as the opening")

        let repeated = SourceIdeaDrafting.mergedDrafts([Array(opening.prefix(2)), [opening[0], ending[0]]])
        #expect(repeated == Array(opening.prefix(2)) + [ending[0]])
    }

    @Test("Depth resolves source, then type, then the fallback")
    func depthResolution() {
        let type = "memoryideastests-\(UUID().uuidString.lowercased())"
        defer { MemoryReviewDepth.setTypeDefault(nil, sourceType: type) }
        #expect(MemoryReviewDepth.effective(sourceDepth: nil, sourceType: type) == .standard)
        MemoryReviewDepth.setTypeDefault(.quick, sourceType: type)
        #expect(MemoryReviewDepth.typeDefault(sourceType: type) == .quick)
        #expect(MemoryReviewDepth.effective(sourceDepth: nil, sourceType: type) == .quick)
        #expect(MemoryReviewDepth.effective(sourceDepth: .deep, sourceType: type) == .deep)
        #expect(SyncedPreferenceKeys.isSynced(MemoryReviewDepth.typePreferenceKey(sourceType: type)))
    }
}

@Suite("Memory ideas storage", .serialized)
struct MemoryIdeasStorageTests {

    private static func temporaryStore() throws -> (KnowledgeStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-memory-ideas-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (try KnowledgeStore(storeDirectory: root), root)
    }

    private static func addSource(_ store: KnowledgeStore, id: String, type: StudioSourceType = .paper) throws {
        // Queued, not ready: a source may only become ready once its text is
        // stored, and none of these tests needs the text.
        try store.saveSource(StudioArticle(url: "https://example.com/\(id)", title: "Source \(id)", sourceType: type, id: id))
    }

    private static func userVersion(at root: URL) -> Int32 {
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            root.appendingPathComponent("knowledge.db").path,
            &db,
            SQLITE_OPEN_READONLY,
            nil
        ) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        var version: Int32 = -1
        if sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            version = sqlite3_column_int(statement, 0)
        }
        sqlite3_finalize(statement)
        return version
    }

    private static func ideas(for sourceID: String, hash: String, count: Int) -> [SourceIdea] {
        (0..<count).map { index in
            SourceIdea(
                id: SourceIdea.id(sourceID: sourceID, contentHash: hash, index: index),
                sourceID: sourceID,
                statement: "Idea \(index) of \(sourceID)",
                recallNote: "note \(index)",
                anchors: [SourceIdeaAnchor(quote: "quote \(index)")],
                wanted: index == 0,
                contentHash: hash,
                sortIndex: index
            )
        }
    }

    @Test("Ideas round-trip, and a new text generation retires the old one")
    func ideasRoundTrip() throws {
        let (store, root) = try Self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.addSource(store, id: "s1")

        let first = Self.ideas(for: "s1", hash: "hash-a", count: 3)
        try store.replaceSourceIdeas(sourceID: "s1", contentHash: "hash-a", ideas: first)
        let loaded = try store.loadSourceIdeas(sourceIDs: ["s1"])["s1"] ?? []
        #expect(loaded.count == 3)
        #expect(loaded.map(\.id) == first.map(\.id))
        #expect(loaded[0].wanted)
        #expect(loaded[0].anchors == [SourceIdeaAnchor(quote: "quote 0")])
        #expect(try store.sourceIdeaContentHash(sourceID: "s1") == "hash-a")

        let second = Self.ideas(for: "s1", hash: "hash-b", count: 2)
        try store.replaceSourceIdeas(sourceID: "s1", contentHash: "hash-b", ideas: second)
        let active = try store.loadSourceIdeas(sourceIDs: ["s1"])["s1"] ?? []
        #expect(active.map(\.id) == second.map(\.id))
        let all = try store.loadSourceIdeas(sourceIDs: ["s1"], includeRetired: true)["s1"] ?? []
        #expect(all.count == 5)
        #expect(all.filter { $0.status == .retired }.map(\.id).sorted() == first.map(\.id).sorted())
        #expect(try store.sourceIdeaContentHash(sourceID: "s1") == "hash-b")

        try store.setSourceIdeaStatus(id: second[0].id, status: .retired)
        #expect(try store.loadSourceIdeas(sourceIDs: ["s1"])["s1"]?.map(\.id) == [second[1].id])
        let retired = try store.loadSourceIdeas(sourceIDs: ["s1"], includeRetired: true)["s1"] ?? []
        #expect(retired.first { $0.id == second[0].id }?.status == .retired)
    }

    @Test("Ideas must belong to the source and hash they replace")
    func ideasRejectForeignRows() throws {
        let (store, root) = try Self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.addSource(store, id: "s1")
        let foreign = Self.ideas(for: "s2", hash: "h", count: 1)
        #expect(throws: KnowledgeStoreError.self) {
            try store.replaceSourceIdeas(sourceID: "s1", contentHash: "h", ideas: foreign)
        }
    }

    /// Generation 2: the depth lives in the source's reading state (§3.5.18), per member, and the
    /// source's own record is not touched by it.
    @Test("Review depth is the reading state's")
    func reviewDepthInReadingState() throws {
        let (store, root) = try Self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.addSource(store, id: "s1")
        try store.setSourceReviewDepth(sourceID: "s1", depth: .quick)
        #expect(try store.loadSourceReviewDepths(sourceIDs: ["s1"])["s1"] == .quick)
        #expect(try store.readingStateReviewDepths(sourceIDs: ["s1"])["s1"] == MemoryReviewDepth.quick.rawValue)
        try store.setSourceReviewDepth(sourceID: "s1", depth: nil)
        #expect(try store.loadSourceReviewDepths(sourceIDs: ["s1"])["s1"] == nil)
        #expect(throws: KnowledgeStoreError.self) {
            try store.setSourceReviewDepth(sourceID: "missing", depth: .quick)
        }
    }

    @Test("A memory chat keeps its kind and briefing, and both ride the session payload")
    func sessionKindAndBriefing() throws {
        let (store, root) = try Self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.addSource(store, id: "s1")
        let sessionID = MemoryReviewSession.sessionID(for: Date())
        try store.createReviewSession(id: sessionID, topic: "Memory", sourceIDs: ["s1"], briefing: "PLAN")
        #expect(try store.loadReviewSessionBriefing(sessionID: sessionID) == "PLAN")

        let plain = UUID().uuidString
        try store.createReviewSession(id: plain, topic: "Chat", sourceIDs: [])
        let plainPayload = try #require(try store.loadReviewSessionForSync(plain))
        #expect(plainPayload.kind == nil)

        let payload = try #require(try store.loadReviewSessionForSync(sessionID))
        #expect(payload.kind == "memory")
        #expect(payload.briefing == "PLAN")

        // A pre-v89 client round-tripping the session sends neither; the local
        // values survive.
        let stripped = CloudKitReviewSessionPayload(
            id: payload.id,
            topic: payload.topic,
            startedAt: payload.startedAt,
            endedAt: payload.endedAt,
            status: payload.status,
            overallScore: payload.overallScore,
            summary: payload.summary,
            sourceIDs: payload.sourceIDs,
            cardIDs: payload.cardIDs,
            exchangeCount: payload.exchangeCount,
            modelProvider: payload.modelProvider,
            modelID: payload.modelID,
            goalID: payload.goalID,
            exchanges: payload.exchanges,
            sourceIdentities: payload.sourceIdentities
        )
        try store.saveReviewSessionRecord(stripped)
        #expect(try store.loadReviewSessionBriefing(sessionID: sessionID) == "PLAN")
        let kept = try #require(try store.loadReviewSessionForSync(sessionID))
        #expect(kept.kind == "memory")
    }

    @Test("A graded contour lands on its exchange, the steer follows it, and the ladder reads both")
    func gradeSteerAndHistory() throws {
        let (store, root) = try Self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.addSource(store, id: "s1", type: .podcast)
        let ideas = Self.ideas(for: "s1", hash: "h", count: 2)
        try store.replaceSourceIdeas(sourceID: "s1", contentHash: "h", ideas: ideas)
        let sessionID = MemoryReviewSession.sessionID(for: Date())
        try store.createReviewSession(id: sessionID, topic: "Memory", sourceIDs: ["s1"])

        _ = try store.addReviewPrompt(sessionID: sessionID, question: "What was it about?", sourceRefs: ["s1"])
        let sequence = try #require(try store.answerPendingReviewExchange(
            sessionID: sessionID,
            answer: "It was about mitochondria.",
            evaluation: "One idea came back.",
            score: 0.5,
            knowledgeNote: nil,
            sourceRefs: ["s1"]
        ))
        let grade = try MemoryContourGrade.validate(
            arguments: [
                "source_id": "s1",
                "score": 0.75,
                "idea_coverage": [
                    ["idea_id": ideas[0].id, "status": "produced"],
                    ["idea_id": ideas[1].id, "status": "partial"],
                ],
            ],
            ideasBySource: ["s1": ideas]
        ).get()
        try store.recordMemoryContourGrade(sessionID: sessionID, sequence: sequence, grade: grade)

        let exchange = try #require(try store.loadReviewSessionExchanges(sessionID: sessionID).last)
        #expect(MemoryIdeaCoverage.decode(exchange.ideaCoverage) == grade.coverage)
        #expect(exchange.questionVerdict == "sound")
        #expect(exchange.operation == "recall")
        #expect(exchange.score == 0.75)
        #expect(exchange.steer == nil)

        // The steer attaches to that grade, once.
        let coverage = try store.recordMemoryReviewSteer(sessionID: sessionID, steer: .next)
        #expect(coverage == grade.coverage)
        #expect(try store.loadReviewSessionExchanges(sessionID: sessionID).last?.steer == "next")
        #expect(try store.recordMemoryReviewSteer(sessionID: sessionID, steer: .deeper) == nil)
        #expect(try store.memoryReviewSteers(sessionID: sessionID).map(\.sourceID) == ["s1"])

        // The ladder sees the graded source as discussed once, on rung 1, even
        // though the memory chat is still active.
        let history = try store.memoryContourHistory()
        #expect(history["s1"]?.count == 1)
        #expect(history["s1"]?.first?.producedFraction == 0.75)
        let candidates = try store.cohortCandidates(now: Date().addingTimeInterval(86_400))
        // No consumption evidence was written, so the source is not a candidate;
        // the rung itself is what this test pins, through the pure function.
        #expect(candidates.allSatisfy { $0.sourceID != "s1" })
        #expect(ForeverLMCore.memoryReviewRung(producedFractions: history["s1"]?.map(\.producedFraction) ?? []) == 1)

        // The exchange payload carries the grade to the other device.
        let payload = try #require(try store.loadReviewSessionForSync(sessionID))
        let synced = try #require(payload.exchanges.last)
        #expect(synced.ideaCoverage == exchange.ideaCoverage)
        #expect(synced.steer == "next")
    }

}

@Suite("Tool argument numbers")
struct ToolArgumentNumberTests {
    @Test("JSON numbers parse, JSON booleans and text do not")
    func parsesWhatJSONDelivers() throws {
        let json = #"{"zero":0,"one":1,"half":0.5,"t":true,"f":false,"s":"0.5","n":null}"#
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        #expect(ToolArgumentNumber.value(parsed["zero"]) == 0)
        #expect(ToolArgumentNumber.value(parsed["one"]) == 1)
        #expect(ToolArgumentNumber.value(parsed["half"]) == 0.5)
        #expect(ToolArgumentNumber.value(parsed["t"]) == nil)
        #expect(ToolArgumentNumber.value(parsed["f"]) == nil)
        #expect(ToolArgumentNumber.value(parsed["s"]) == nil)
        #expect(ToolArgumentNumber.value(parsed["n"]) == nil)
        #expect(ToolArgumentNumber.value(parsed["missing"]) == nil)
        // Swift values a test or the phone's decoder hands over behave the same.
        #expect(ToolArgumentNumber.value(0.0) == 0)
        #expect(ToolArgumentNumber.value(1) == 1)
        #expect(ToolArgumentNumber.value(true) == nil)
    }

    @Test("A rejected argument is described as it arrived")
    func describesWhatArrived() throws {
        let json = #"{"t":true,"s":"0.5","n":null,"x":1.5}"#
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        #expect(ToolArgumentNumber.describe(parsed["t"]) == "the boolean true")
        #expect(ToolArgumentNumber.describe(parsed["s"]) == "the string \"0.5\"")
        #expect(ToolArgumentNumber.describe(parsed["n"]) == "null")
        #expect(ToolArgumentNumber.describe(parsed["x"]) == "the number 1.5")
        #expect(ToolArgumentNumber.describe(parsed["missing"]) == "nothing (the key was omitted)")
    }
}
