import Foundation
import Testing
@testable import ForeverLM

/// The phone derives review candidates from synced records the way the Mac's
/// query derives them from SQL. These pin the facts the two must agree on.
@Suite("Phone memory review candidates")
struct MemoryReviewCandidatesTests {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func day(
        _ sourceID: String,
        daysAgo: Int,
        fraction: Double,
        completed: Bool = false,
        engagedSeconds: Double = 600,
        kinds: Set<SourceActivityKind> = [.reading]
    ) -> SourceActivityDay {
        let at = now.addingTimeInterval(-Double(daysAgo) * 86_400)
        return SourceActivityDay(
            id: "\(sourceID)-\(daysAgo)",
            sourceID: sourceID,
            dayStart: at,
            firstActivityAt: at,
            lastActivityAt: at,
            kinds: kinds,
            completedKinds: completed ? kinds : [],
            maxFraction: fraction,
            engagedSeconds: engagedSeconds
        )
    }

    private func source(
        _ id: String,
        readAt: Date? = nil,
        available: Bool = true,
        wordCount: Int? = nil,
        annotationCount: Int = 0
    ) -> MemoryReviewCandidates.SourceInput {
        .init(
            id: id, title: id.capitalized, sourceType: "article", dateAdded: now.addingTimeInterval(-30 * 86_400),
            readAt: readAt, isAvailable: available, wordCount: wordCount, annotationCount: annotationCount
        )
    }

    // MARK: - The engagement ledger

    @Test("Depth needs time behind it, a chat the learner wrote in is consumption, and a highlight lifts a level")
    func engagementLedger() throws {
        let talked = now.addingTimeInterval(-20 * 3_600)
        let summary = ReviewableChat.summary(
            title: "About the paper", kind: nil, hasCardIDs: false, overallScore: nil,
            exchanges: [.init(sequenceNumber: 1, question: "", userAnswer: "What does it claim?", evaluation: "This.", answeredAt: talked)],
            startedAt: talked, endedAt: nil
        )
        // Two sources attached, both cited in the reply: a chat about both.
        let chat = MemoryReviewCandidates.SessionInput(
            id: "chat", status: "active", occurredAt: talked, sourceIDs: ["talked", "talked-and-read"],
            gradedContours: [], chat: summary, lastLearnerTurnAt: talked,
            citedSourceIDs: ["talked", "talked-and-read"]
        )
        #expect(chat.isChatDiscussion)
        let quiz = MemoryReviewCandidates.SessionInput(
            id: "quiz", status: "active", occurredAt: talked, sourceIDs: ["quizzed"], gradedContours: [],
            chat: ReviewableChat.summary(
                title: "Quiz", kind: nil, hasCardIDs: false, overallScore: nil,
                exchanges: [.init(sequenceNumber: 1, question: "Q", userAnswer: "A", evaluation: "E", score: 0.8, answeredAt: talked)],
                startedAt: talked, endedAt: nil
            ),
            lastLearnerTurnAt: talked
        )
        #expect(!quiz.isChatDiscussion)

        let candidates = MemoryReviewCandidates.candidates(
            sources: [
                source("skimmed", wordCount: 3_000),
                source("read", wordCount: 3_000),
                source("talked"),
                source("talked-and-read"),
                source("quizzed"),
                source("marked", annotationCount: 2),
            ],
            activityDays: [
                // Paged to the end in forty seconds: a position, not a read.
                "skimmed": [day("skimmed", daysAgo: 1, fraction: 1.0, engagedSeconds: 40)],
                // The same depth with the time to back it.
                "read": [day("read", daysAgo: 1, fraction: 1.0, engagedSeconds: 500)],
                // Read three weeks ago, talked about yesterday: yesterday's material.
                "talked-and-read": [day("talked-and-read", daysAgo: 21, fraction: 0.8)],
                "quizzed": [day("quizzed", daysAgo: 1, fraction: 0.2)],
                // Too shallow on its own; the highlights say otherwise.
                "marked": [day("marked", daysAgo: 1, fraction: 0.4)],
            ],
            sessions: [chat, quiz],
            now: now
        )
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.sourceID, $0) })
        #expect(byID["skimmed"] == nil)
        #expect(byID["quizzed"] == nil)
        #expect(byID["read"]?.confidence == .complete)
        #expect(byID["read"]?.engagement.engagedSeconds == 500)
        #expect(byID["talked"]?.confidence == .substantial)
        #expect(byID["talked"]?.consumedAt == talked)
        #expect(byID["talked-and-read"]?.consumedAt == talked)
        #expect(byID["talked-and-read"]?.engagement.chatDiscussedAt == talked)
        #expect(byID["marked"]?.confidence == .substantial)
        #expect(byID["marked"]?.engagement.annotationCount == 2)

        // The skim is still bridgeable, as a partial read.
        let bridgeable = MemoryReviewCandidates.candidates(
            sources: [source("skimmed", wordCount: 3_000)],
            activityDays: ["skimmed": [day("skimmed", daysAgo: 1, fraction: 1.0, engagedSeconds: 40)]],
            sessions: [], now: now, minimumConfidence: .partial
        )
        #expect(bridgeable.first?.confidence == .partial)
    }

    @Test("A chat vouches for the sources it cites, or the one it was opened on; a Notebook's shelf behind a broad question is not discussed")
    func broadChatVouchesOnlyForCitations() {
        let talked = now.addingTimeInterval(-20 * 3_600)
        func chat(_ id: String, attached: [String], cited: [String]) -> MemoryReviewCandidates.SessionInput {
            MemoryReviewCandidates.SessionInput(
                id: id, status: "active", occurredAt: talked, sourceIDs: attached, gradedContours: [],
                chat: ReviewableChat.summary(
                    title: "Membrane potentials", kind: nil, hasCardIDs: false, overallScore: nil,
                    exchanges: [.init(sequenceNumber: 1, question: "", userAnswer: "Explain the membrane potential.", evaluation: "Across both membranes.", answeredAt: talked)],
                    startedAt: talked, endedAt: nil
                ),
                lastLearnerTurnAt: talked, citedSourceIDs: cited
            )
        }
        let shelf = (1...5).map { "paper-\($0)" }
        // One question across a whole Notebook, the reply citing one paper.
        let broad = chat("broad", attached: shelf, cited: ["paper-2"])
        // A chat opened from one paper's reader, the tutor never linking it.
        let single = chat("single", attached: ["opened-alone"], cited: [])
        // A chat with nothing attached whose reply cites a library source.
        let cold = chat("cold", attached: [], cited: ["found-by-search"])
        #expect(ChatSourceEvidence.discussedSourceIDs(attached: shelf, cited: ["paper-2"]) == ["paper-2"])
        #expect(ChatSourceEvidence.discussedSourceIDs(attached: ["opened-alone"], cited: []) == ["opened-alone"])
        #expect(ChatSourceEvidence.discussedSourceIDs(attached: ["a", "b"], cited: []).isEmpty)

        let discussed = MemoryReviewCandidates.chatDiscussions(sessions: [broad, single, cold], now: now)
        #expect(Set(discussed.keys) == ["paper-2", "opened-alone", "found-by-search"])

        let candidates = MemoryReviewCandidates.candidates(
            sources: shelf.map { source($0) } + [source("opened-alone"), source("found-by-search")],
            activityDays: [:],
            sessions: [broad, single, cold],
            now: now
        ).filter { $0.sourceType != ReviewableChat.sourceType }
        #expect(Set(candidates.map(\.sourceID)) == ["paper-2", "opened-alone", "found-by-search"])
        #expect(candidates.allSatisfy { $0.confidence == .substantial && $0.consumedAt == talked })
    }

    @Test("Cited sources are read out of an exchange's turns by their in-app links")
    func citationsAreReadFromTurns() {
        let tokens = ChatSourceEvidence.sourceLinkTokens(
            question: nil,
            userAnswer: "What does [this](foreverlm://source/src_learner) say about [that](foreverlm://source/src_shared)?",
            evaluation: "It says so [here](foreverlm://source/src_shared?t=754) and [there](FOREVERLM://SOURCE/src_reply#t=1m)."
        )
        #expect(tokens == ["src_learner", "src_shared", "src_reply"])
        #expect(ChatSourceEvidence.sourceLinkTokens(question: "", userAnswer: "No links.", evaluation: nil).isEmpty)
    }

    @Test("A bare link's sentence punctuation and emphasis are not part of the source it cites")
    func bareLinkPunctuationIsNotPartOfTheToken() {
        let tokens = ChatSourceEvidence.sourceLinkTokens(
            question: nil,
            userAnswer: "See foreverlm://source/src_one. Then **foreverlm://source/src_two**, and \u{201C}foreverlm://source/src_three\u{201D};",
            evaluation: "Also _foreverlm://source/src_four_! Or foreverlm://source/src_one: the same source again."
        )
        #expect(tokens == ["src_one", "src_two", "src_three", "src_four"])
    }

    @Test("The day's ledger and the touched list come from the same records")
    func ledgerAndTouched() {
        let since = MemoryReviewLedger.windowStart(now: now)
        let inWindow = since.addingTimeInterval(7_200)
        func at(_ id: String, fraction: Double, seconds: Double, kinds: Set<SourceActivityKind> = [.reading]) -> SourceActivityDay {
            SourceActivityDay(
                id: "\(id)-w", sourceID: id, dayStart: since, firstActivityAt: inWindow, lastActivityAt: inWindow,
                kinds: kinds, completedKinds: [], maxFraction: fraction, engagedSeconds: seconds
            )
        }
        let sources = [source("read"), source("glanced"), source("heard"), source("old"), source("hidden", available: false)]
        let days: [String: [SourceActivityDay]] = [
            "read": [at("read", fraction: 0.9, seconds: 1_200)],
            "glanced": [at("glanced", fraction: 0.1, seconds: 40)],
            "heard": [at("heard", fraction: 0.5, seconds: 500, kinds: [.listening])],
            "old": [day("old", daysAgo: 5, fraction: 1)],
            "hidden": [at("hidden", fraction: 1, seconds: 900)],
        ]
        let chat = MemoryReviewCandidates.SessionInput(
            id: "chat", status: "active", occurredAt: inWindow, sourceIDs: ["read"], gradedContours: [],
            chat: ReviewableChat.summary(
                title: "T", kind: nil, hasCardIDs: false, overallScore: nil,
                exchanges: [.init(sequenceNumber: 1, question: "", userAnswer: "Why?", evaluation: "Because.", answeredAt: inWindow)],
                startedAt: inWindow, endedAt: nil
            ),
            lastLearnerTurnAt: inWindow
        )
        let ledger = MemoryReviewCandidates.ledger(sources: sources, activityDays: days, sessions: [chat], since: since, now: now)
        #expect(ledger.sourceCount == 3)
        #expect(ledger.engagedSeconds == 1_740)
        #expect(ledger.chatDiscussedCount == 1)
        #expect(ledger.listenedCount == 1)
        #expect(ledger.line() == "Yesterday and today: 3 sources · 29m · 1 discussed in chats · 1 listened")

        let touched = MemoryReviewCandidates.touched(sources: sources, activityDays: days, since: since, now: now, excluding: ["read"])
        #expect(touched.map(\.sourceID) == ["heard", "glanced"])
        #expect(touched.first?.engagedSeconds == 500)
        #expect(touched.last?.depth == 0.1)
    }

    @Test("A source counts once it was read, or reached deep enough, and is dated by that evidence")
    func consumptionEvidence() {
        let readAt = now.addingTimeInterval(-2 * 86_400)
        let candidates = MemoryReviewCandidates.candidates(
            sources: [
                source("read", readAt: readAt),
                source("deep"),
                source("shallow"),
                source("hidden", readAt: readAt, available: false),
            ],
            activityDays: [
                "deep": [day("deep", daysAgo: 5, fraction: 0.7)],
                "shallow": [day("shallow", daysAgo: 1, fraction: 0.1)],
            ],
            sessions: [],
            now: now
        )
        #expect(candidates.map(\.sourceID) == ["deep", "read"])
        #expect(candidates[1].consumedAt == readAt)
        #expect(candidates[1].confidence == .complete)
        #expect(candidates[0].confidence == .substantial)
        #expect(candidates[0].consumedAt == now.addingTimeInterval(-5 * 86_400))
    }

    @Test("Completed sessions are the review history; an active memory chat counts through its graded contours")
    func reviewHistory() {
        let readAt = now.addingTimeInterval(-20 * 86_400)
        let discussed = now.addingTimeInterval(-6 * 86_400)
        let graded = now.addingTimeInterval(-1 * 86_400)
        let ideaID = SourceIdea.id(sourceID: "paper", contentHash: "h", index: 0)
        let coverage = MemoryIdeaCoverage.encode([MemoryIdeaCoverage(ideaID: ideaID, status: .produced)])
        let contour = MemoryReviewCandidates.gradedContour(ideaCoverage: coverage, questionVerdict: "sound", answeredAt: graded)
        #expect(contour?.sourceID == "paper")
        #expect(contour?.producedFraction == 1)

        let candidates = MemoryReviewCandidates.candidates(
            sources: [source("paper", readAt: readAt)],
            activityDays: [:],
            sessions: [
                .init(id: "s1", status: "completed", occurredAt: discussed, sourceIDs: ["paper"], gradedContours: []),
                .init(id: "memory-2026-09-03", status: "active", occurredAt: graded, sourceIDs: ["paper"], gradedContours: [contour!]),
            ],
            now: now
        )
        let paper = candidates[0]
        #expect(paper.reviewCount == 1)
        #expect(paper.lastDiscussedAt == graded)
        #expect(paper.contourRung == ForeverLMCore.memoryReviewRung(producedFractions: [1]))
    }

    @Test("An ambiguous verdict contributes no fraction to the ladder")
    func ambiguousContour() {
        let ideaID = SourceIdea.id(sourceID: "s", contentHash: "h", index: 0)
        let coverage = MemoryIdeaCoverage.encode([MemoryIdeaCoverage(ideaID: ideaID, status: .missing)])
        let contour = MemoryReviewCandidates.gradedContour(ideaCoverage: coverage, questionVerdict: "ambiguous", answeredAt: now)
        #expect(contour?.producedFraction == nil)
        #expect(MemoryReviewCandidates.gradedContour(ideaCoverage: nil, questionVerdict: nil, answeredAt: now) == nil)
    }

    // MARK: - Chats as material

    private func exchange(
        _ sequence: Int,
        learner: String?,
        reply: String?,
        score: Double? = nil,
        at answeredAt: Date? = nil
    ) -> ReviewableChat.Exchange {
        ReviewableChat.Exchange(
            sequenceNumber: sequence,
            question: "",
            userAnswer: learner,
            evaluation: reply,
            score: score,
            answeredAt: answeredAt
        )
    }

    private func chatSession(
        _ id: String,
        title: String = "Mito Biotechs",
        kind: String? = nil,
        status: String = "active",
        exchanges: [ReviewableChat.Exchange],
        startedAt: Date,
        gradedContours: [MemoryReviewCandidates.GradedContour] = []
    ) -> MemoryReviewCandidates.SessionInput {
        .init(
            id: id,
            status: status,
            occurredAt: startedAt,
            sourceIDs: [],
            gradedContours: gradedContours,
            chat: ReviewableChat.summary(
                title: title,
                kind: kind,
                hasCardIDs: false,
                overallScore: nil,
                exchanges: exchanges,
                startedAt: startedAt,
                endedAt: nil
            )
        )
    }

    @Test("An ordinary chat the learner took part in is review material; a memory chat, a graded quiz and a thin chat are not")
    func chatsAreCandidates() {
        let long = String(repeating: "The tutor explains heteroplasmy shifting at some length. ", count: 10)
        let started = now.addingTimeInterval(-2 * 86_400)
        let talked = now.addingTimeInterval(-86_400)
        let candidates = MemoryReviewCandidates.candidates(
            sources: [],
            activityDays: [:],
            sessions: [
                chatSession("chat", exchanges: [exchange(1, learner: "Which companies edit mtDNA?", reply: long, at: talked)], startedAt: started),
                chatSession("thin", exchanges: [exchange(1, learner: "Thanks", reply: "Any time.", at: talked)], startedAt: started),
                chatSession("quiz", exchanges: [exchange(1, learner: "It is about selection.", reply: long, score: 0.8, at: talked)], startedAt: started),
                chatSession("unattended", exchanges: [exchange(1, learner: nil, reply: long, at: talked)], startedAt: started),
                chatSession(MemoryReviewSession.sessionID(for: talked), exchanges: [exchange(1, learner: "Recall", reply: long, at: talked)], startedAt: started),
                chatSession("review-kind", kind: ReviewSessionKind.review.rawValue, exchanges: [exchange(1, learner: "A", reply: long, at: talked)], startedAt: started),
                chatSession("linked", status: "external_link", exchanges: [exchange(1, learner: "A", reply: long, at: talked)], startedAt: started),
                chatSession("tomorrow", exchanges: [exchange(1, learner: "A", reply: long, at: now.addingTimeInterval(3_600))], startedAt: started),
            ],
            now: now
        )
        #expect(candidates.map(\.sourceID) == ["chat"])
        let chat = candidates[0]
        #expect(chat.sourceType == ReviewableChat.sourceType)
        #expect(chat.title == "Mito Biotechs")
        #expect(chat.consumedAt == talked)
        #expect(chat.confidence == .complete)
        #expect(chat.reviewCount == 0)
        #expect(chat.lastDiscussedAt == nil)
        #expect(chat.contourRung == nil)
    }

    @Test("A chat's ladder is the contours graded against its ideas, whose ids name the session")
    func chatLadderComesFromItsContours() throws {
        let long = String(repeating: "Selection favours corrected genomes when quality control removes the rest. ", count: 8)
        let started = now.addingTimeInterval(-9 * 86_400)
        let talked = now.addingTimeInterval(-8 * 86_400)
        let graded = now.addingTimeInterval(-7 * 86_400)
        let ideaID = SourceIdea.id(sourceID: "chat", contentHash: "abc", index: 0)
        let coverage = MemoryIdeaCoverage.encode([MemoryIdeaCoverage(ideaID: ideaID, status: .produced)])
        let contour = MemoryReviewCandidates.gradedContour(ideaCoverage: coverage, questionVerdict: "sound", answeredAt: graded)
        let review = MemoryReviewCandidates.SessionInput(
            id: MemoryReviewSession.sessionID(for: graded),
            status: "active",
            occurredAt: graded,
            sourceIDs: [],
            gradedContours: [contour].compactMap { $0 }
        )
        let candidates = MemoryReviewCandidates.candidates(
            sources: [],
            activityDays: [:],
            sessions: [
                chatSession("chat", exchanges: [exchange(1, learner: "Why does QC matter?", reply: long, at: talked)], startedAt: started),
                review,
            ],
            now: now
        )
        let chat = try #require(candidates.first { $0.sourceID == "chat" })
        #expect(chat.reviewCount == 1)
        #expect(chat.lastDiscussedAt == graded)
        #expect(chat.contourRung == 1)
    }

    @Test("The transcript reads the same on every client: the title, then the turns in exchange order")
    func transcriptIsDeterministic() {
        let exchanges = [
            ReviewableChat.Exchange(sequenceNumber: 2, question: "", userAnswer: " Second question ", evaluation: "Second reply"),
            ReviewableChat.Exchange(sequenceNumber: 1, question: "Opening reply", userAnswer: "First question", evaluation: nil),
            ReviewableChat.Exchange(sequenceNumber: 3, question: "", userAnswer: "   ", evaluation: nil),
        ]
        let transcript = ReviewableChat.transcript(title: " Mito Biotechs ", exchanges: exchanges)
        #expect(transcript == """
        CHAT: Mito Biotechs

        ForeverLM:
        Opening reply

        You:
        First question

        You:
        Second question

        ForeverLM:
        Second reply
        """)
        #expect(SourceIdeaDrafting.contentHash(transcript) == SourceIdeaDrafting.contentHash(
            ReviewableChat.transcript(title: "Mito Biotechs", exchanges: exchanges.reversed())
        ))
    }
}
