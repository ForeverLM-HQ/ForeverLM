import CryptoKit
import Foundation
import Testing
@testable import ForeverLM

@Suite("Mobile voice source resolver")
struct MobileVoiceSourceResolverTests {

    @Test("Reader completion requires the actual document end")
    func readerCompletionRequiresEnd() {
        #expect(!MobileReadingCompletion.reachedEnd(.nan))
        #expect(!MobileReadingCompletion.reachedEnd(0.8))
        #expect(!MobileReadingCompletion.reachedEnd(0.9949))
        #expect(MobileReadingCompletion.reachedEnd(0.995))
        #expect(MobileReadingCompletion.reachedEnd(1))
    }

    @Test("A synced domain that is a book chapter's folder path gives the row no subtitle")
    func domainPathIsNoSubtitle() {
        #expect(MobileCloudSource.subtitle(fromDomain: "/Users/learner/Library/Mobile Documents/Books/SystemsBiology/Chapters") == nil)
        #expect(MobileCloudSource.subtitle(fromDomain: "  ") == nil)
        #expect(MobileCloudSource.subtitle(fromDomain: nil) == nil)
        #expect(MobileCloudSource.subtitle(fromDomain: "martinpicard.substack.com") == "martinpicard.substack.com")
    }

    @Test("Latest-paper shortcut selects the newest paper, not a newer article")
    func latestPaperShortcutFiltersBeforeSelectingNewest() throws {
        let sources = [
            source(
                id: "newest-article",
                title: "Newest article",
                subtitle: nil,
                sourceType: "article",
                daysAgo: 0
            ),
            source(
                id: "newest-paper",
                title: "Newest paper",
                subtitle: nil,
                sourceType: "paper",
                daysAgo: 1
            ),
            source(
                id: "older-paper",
                title: "Older paper",
                subtitle: nil,
                sourceType: "paper",
                daysAgo: 5
            ),
        ]

        let selected = try #require(
            MobileLatestSourceSelector.latest(in: sources, sourceType: "paper")
        )

        #expect(selected.id == "newest-paper")
    }

    @Test("Portable memory anchors reconcile by published DOI only when the exact source ID is absent")
    func portableMemoryAnchorReconciliation() {
        var canonical = source(
            id: "local-source",
            title: "Canonical paper",
            subtitle: nil,
            sourceType: "paper",
            daysAgo: 1
        )
        canonical.publishedDOI = "10.1000/ABC"
        var exact = source(
            id: "remote-source",
            title: "Exact synced record",
            subtitle: nil,
            sourceType: "paper",
            daysAgo: 2
        )
        exact.publishedDOI = "10.1000/other"
        let item = MemoryItem(
            id: "memory",
            kind: .concept,
            target: "Explain the result",
            rubricJSON: #"{"criteria":["Names the mechanism"]}"#,
            sources: [
                MemoryItemSource(
                    id: "anchor",
                    memoryItemID: "memory",
                    sourceID: "remote-source",
                    excerpt: "Canonical evidence",
                    sourceSHA256: String(repeating: "a", count: 64),
                    sortIndex: 0
                ),
            ]
        )
        let identities = [
            MobileMemorySourceIdentity(
                sourceID: "remote-source",
                url: nil,
                normalizedURL: nil,
                doi: nil,
                publishedDOI: "10.1000/abc"
            ),
        ]

        let exactResult = MobileMemorySourceIdentityResolver.remap(
            item: item,
            identities: identities,
            sources: [canonical, exact],
            normalizeURL: { $0 }
        )
        #expect(exactResult.sources.map(\.sourceID) == ["remote-source"])

        let remapped = MobileMemorySourceIdentityResolver.remap(
            item: item,
            identities: identities + identities,
            sources: [canonical],
            normalizeURL: { $0 }
        )
        #expect(remapped.sources.map(\.sourceID) == ["local-source"])

        let remoteKey = MemoryTutorIdentity.portableSourceKey(
            sourceID: "remote-source",
            publishedDOI: "10.1000/abc"
        )
        let localKey = MemoryTutorIdentity.portableSourceKey(
            sourceID: "local-source",
            publishedDOI: canonical.publishedDOI
        )
        let remoteItemID = MemoryTutorIdentity.firstReviewItemID(
            portableSourceKey: remoteKey
        )
        let localItemID = MemoryTutorIdentity.firstReviewItemID(
            portableSourceKey: localKey
        )
        #expect(remoteItemID == localItemID)
        #expect(
            MemoryTutorIdentity.firstReviewAnchorID(memoryItemID: remoteItemID)
                == MemoryTutorIdentity.firstReviewAnchorID(memoryItemID: localItemID)
        )
        #expect(
            MemoryTutorIdentity.scheduledSourcePlacementID(portableSourceKey: remoteKey)
                == MemoryTutorIdentity.scheduledSourcePlacementID(portableSourceKey: localKey)
        )
    }

    @Test("Portable DOI ambiguity resolves in the same order as Mac storage")
    func portableDOIAmbiguityMatchesMac() {
        var publishedOnly = source(
            id: "a-published-only",
            title: "Published DOI alias",
            subtitle: nil,
            sourceType: "paper",
            daysAgo: 1
        )
        publishedOnly.publishedDOI = "10.1000/shared"
        var regularDOI = source(
            id: "z-regular-doi",
            title: "Regular DOI authority",
            subtitle: nil,
            sourceType: "paper",
            daysAgo: 1
        )
        regularDOI.doi = "10.1000/shared"
        let index = MobileMemorySourceIdentityResolver.Index(
            sources: [publishedOnly, regularDOI],
            normalizeURL: { $0 }
        )

        // Mac's sourceIDByDOI checks papers.doi before papers.published_doi
        // for each remote candidate, regardless of source-ID sort order.
        #expect(index.resolvedSourceID(
            "missing-remote",
            identity: MobileMemorySourceIdentity(
                sourceID: "missing-remote",
                url: nil,
                normalizedURL: nil,
                doi: "10.1000/SHARED",
                publishedDOI: nil
            )
        ) == "z-regular-doi")
        #expect(index.resolvedSourceID(
            "missing-published-remote",
            identity: MobileMemorySourceIdentity(
                sourceID: "missing-published-remote",
                url: nil,
                normalizedURL: nil,
                doi: nil,
                publishedDOI: "10.1000/shared"
            )
        ) == "z-regular-doi")
    }

    @Test("Phone legacy review projection matches Mac aggregate semantics")
    func legacyReviewProjection() {
        let paper = source(
            id: "paper",
            title: "A reviewed paper",
            subtitle: nil,
            sourceType: "paper",
            daysAgo: 10
        )
        let older = Date(timeIntervalSinceReferenceDate: 100)
        let newer = Date(timeIntervalSinceReferenceDate: 200)
        let stats = MobileLegacyMemoryReviewProjector.stats(
            sessions: [
                MobileLegacyReviewSession(date: older, score: 0.4, sourceIDs: ["paper", "paper"]),
                MobileLegacyReviewSession(date: newer, score: nil, sourceIDs: ["paper"]),
            ],
            sources: [paper]
        )

        #expect(stats.count == 1)
        #expect(stats.first?.lastReviewedAt == newer)
        #expect(stats.first?.lastScore == 0.4)
        #expect(stats.first?.reviewCount == 2)
        #expect(MobileLegacyMemoryReviewProjector.stats(
            sessions: [MobileLegacyReviewSession(date: newer, score: 0.8, sourceIDs: ["paper"])],
            sources: [paper],
            excludingSourceIDs: ["paper"]
        ).isEmpty)
    }

    @Test("Phone notebooks only attempted memory anchors from a multi-source session")
    func attemptedMemorySourceProjection() {
        let item = MemoryItem(
            id: "item-a",
            kind: .concept,
            target: "Explain A",
            rubricJSON: #"{"criteria":["Names A"]}"#,
            sources: [
                MemoryItemSource(
                    id: "anchor-a",
                    memoryItemID: "item-a",
                    sourceID: "source-a",
                    excerpt: "Exact evidence for source A.",
                    sourceSHA256: String(repeating: "a", count: 64),
                    sortIndex: 0
                ),
            ]
        )
        let untouchedItem = MemoryItem(
            id: "item-b",
            kind: .concept,
            target: "Explain B",
            rubricJSON: #"{"criteria":["Names B"]}"#,
            sources: [
                MemoryItemSource(
                    id: "anchor-b",
                    memoryItemID: "item-b",
                    sourceID: "source-b",
                    excerpt: "Exact evidence for source B.",
                    sourceSHA256: String(repeating: "b", count: 64),
                    sortIndex: 0
                ),
            ]
        )
        let attempted = MemoryAttempt(
            id: "attempt-a",
            memoryItemID: item.id,
            sessionID: "session-partial",
            exchangeID: "exchange-a",
            prompt: "Explain A",
            learnerAnswer: "A works because…",
            feedback: "Good",
            score: 0.8,
            scheduleRating: .good,
            gradeState: .graded
        )
        let itemBeforeAttempt = MemoryAttempt(
            id: "attempt-before-item",
            memoryItemID: "item-not-arrived",
            sessionID: "session-out-of-order",
            exchangeID: "exchange-b",
            prompt: "Explain B",
            learnerAnswer: "B…",
            feedback: "Try again",
            score: 0.2,
            scheduleRating: .again,
            gradeState: .graded
        )
        let failedGrade = MemoryAttempt(
            id: "attempt-failed-b",
            memoryItemID: untouchedItem.id,
            sessionID: "session-partial",
            exchangeID: "exchange-failed-b",
            prompt: "Explain B",
            learnerAnswer: "B…",
            feedback: nil,
            score: nil,
            scheduleRating: nil,
            gradeState: .failed,
            gradingError: "The selected grader was unavailable."
        )

        let projection = MobileMemoryAttemptSourceProjection.bySession(
            // Both items were in the launch queue, but the learner stopped
            // after answering A. B must remain pending on every device.
            items: [item, untouchedItem],
            attempts: [attempted, itemBeforeAttempt, failedGrade]
        )

        #expect(projection["session-partial"] == Set(["source-a"]))
        // An attempt arriving before its MemoryItem must suppress the session's
        // full launch queue until its authoritative anchors arrive.
        #expect(projection["session-out-of-order"] == Set<String>())
        #expect(MobileMemoryAttemptSourceProjection.successfullyGradedSourceIDs(
            items: [item, untouchedItem],
            attempts: [attempted, failedGrade],
            sessionID: "session-partial"
        ) == ["source-a"])
        #expect(MobileMemoryAttemptSourceProjection.successfullyGradedSourceIDs(
            items: [untouchedItem],
            attempts: [failedGrade],
            sessionID: "session-partial"
        ) == [])
        #expect(MobileMemoryAttemptSourceProjection.successfullyGradedSourceIDs(
            items: [item, untouchedItem],
            attempts: [itemBeforeAttempt],
            sessionID: "session-out-of-order"
        ) == nil)
    }

    @Test("Phone withholds attempts until their exact parent curriculum exists")
    func memoryAttemptCurriculumProjection() {
        let parent = MemoryItem(
            id: "item-parent",
            kind: .concept,
            target: "Explain the canonical mechanism",
            rubricJSON: #"{"criteria":["Names the mechanism"]}"#,
            sources: [
                MemoryItemSource(
                    id: "portable-anchor",
                    memoryItemID: "item-parent",
                    sourceID: "local-source",
                    excerpt: "Canonical evidence.",
                    sourceSHA256: String(repeating: "a", count: 64),
                    sortIndex: 0
                ),
            ]
        )
        let remappedParent = parent.replacingSources([
            MemoryItemSource(
                id: parent.sources[0].id,
                memoryItemID: parent.id,
                sourceID: "foreign-source",
                excerpt: parent.sources[0].excerpt,
                sourceSHA256: parent.sources[0].sourceSHA256,
                sortIndex: parent.sources[0].sortIndex
            ),
        ])
        let divergentParent = MemoryItem(
            id: parent.id,
            kind: parent.kind,
            target: "Explain a different mechanism",
            rubricJSON: parent.rubricJSON,
            sources: parent.sources
        )
        func attempt(_ id: String, itemID: String = parent.id) -> MemoryAttempt {
            MemoryAttempt(
                id: id,
                memoryItemID: itemID,
                prompt: "What causes it?",
                learnerAnswer: "The mechanism does.",
                feedback: "Grounded feedback",
                score: 0.8,
                scheduleRating: .good,
                gradeState: .graded
            )
        }

        let expected = MemoryTutorIdentity.immutableCurriculumFingerprint(parent)
        #expect(
            MemoryTutorIdentity.immutableCurriculumFingerprint(remappedParent) == expected
        )
        let projected = MobileMemoryAttemptCurriculumProjection.compatibleAttempts(
            items: [remappedParent],
            envelopesByRecordName: [
                "matching-v2": MobileCloudMemoryAttemptPayload(
                    payloadVersion: 2,
                    attempt: attempt("matching"),
                    parentCurriculumFingerprint: expected
                ),
                "divergent-v2": MobileCloudMemoryAttemptPayload(
                    payloadVersion: 2,
                    attempt: attempt("divergent"),
                    parentCurriculumFingerprint: MemoryTutorIdentity
                        .immutableCurriculumFingerprint(divergentParent)
                ),
                "missing-v2": MobileCloudMemoryAttemptPayload(
                    payloadVersion: 2,
                    attempt: attempt("missing-v2")
                ),
                "missing-parent": MobileCloudMemoryAttemptPayload(
                    payloadVersion: 2,
                    attempt: attempt("missing-parent", itemID: "item-not-arrived"),
                    parentCurriculumFingerprint: expected
                ),
                "legacy-v1": MobileCloudMemoryAttemptPayload(
                    payloadVersion: 1,
                    attempt: attempt("legacy")
                ),
            ]
        )

        #expect(Set(projected.keys) == Set(["matching-v2", "legacy-v1"]))
        #expect(projected["matching-v2"]?.id == "matching")
        #expect(projected["legacy-v1"]?.id == "legacy")
    }

    @Test("Phone applies Notebook scope before the due queue limit")
    func notebookMemoryScopePrecedesLimit() {
        let now = Date(timeIntervalSinceReferenceDate: 10_000_000)
        func item(_ id: String, sourceIDs: [String], ageDays: Double) -> MemoryItem {
            MemoryItem(
                id: id,
                kind: sourceIDs.count > 1 ? .relationship : .concept,
                target: "Explain \(id)",
                rubricJSON: #"{"criteria":["Explains it"]}"#,
                sources: sourceIDs.enumerated().map { index, sourceID in
                    MemoryItemSource(
                        id: "\(id)-anchor-\(index)",
                        memoryItemID: id,
                        sourceID: sourceID,
                        excerpt: "Evidence for \(sourceID)",
                        sourceSHA256: String(repeating: "a", count: 64),
                        sortIndex: index
                    )
                },
                createdAt: now.addingTimeInterval(-ageDays * 86_400),
                updatedAt: now.addingTimeInterval(-ageDays * 86_400)
            )
        }

        let outsiders = (0..<12).map {
            item("outsider-\($0)", sourceIDs: ["outside-\($0)"], ageDays: 100)
        }
        let notebookItem = item("notebook", sourceIDs: ["notebook-source"], ageDays: 10)
        let crossNotebook = item(
            "cross-notebook",
            sourceIDs: ["notebook-source", "outside-cross"],
            ageDays: 50
        )
        let allItems = outsiders + [crossNotebook, notebookItem]
        let allSourceIDs = Set(allItems.flatMap { $0.sources.map(\.sourceID) })

        let eligible = MobileMemoryReviewScope.eligibleItems(
            allItems,
            availableSourceIDs: allSourceIDs,
            restrictToSourceIDs: ["notebook-source"]
        )
        // Each reviewed once when it was kept: a never-reviewed item is new,
        // never due, and the card queue introduces it instead.
        let schedules = Dictionary(uniqueKeysWithValues: eligible.map { item in
            (item.id, MemoryTutorScheduler.schedule(item: item, attempts: [
                MemoryAttempt(
                    id: "review-\(item.id)",
                    memoryItemID: item.id,
                    prompt: "Explain \(item.id)",
                    learnerAnswer: "An answer",
                    score: 0.8,
                    scheduleRating: .good,
                    gradeState: .graded,
                    attemptedAt: item.createdAt
                ),
            ]))
        })
        let due = MemoryTutorScheduler.dueItems(
            items: eligible,
            schedules: schedules,
            now: now,
            limit: 12
        )

        #expect(eligible.map(\.id) == ["notebook"])
        #expect(due.map(\.id) == ["notebook"])
    }

    @Test("Natural-language source identity fails closed")
    func naturalLanguageIdentityFailsClosed() throws {
        let sources = [
            source(
                id: "older-picard",
                title: "Martin Picard: Mitochondria and the Mind",
                subtitle: "martinpicard.substack.com",
                sourceType: "article",
                daysAgo: 10
            ),
            source(
                id: "latest-picard",
                title: "Martin Picard: The Energy of Feeling",
                subtitle: "martinpicard.substack.com",
                sourceType: "article",
                daysAgo: 1
            ),
            source(
                id: "unrelated-latest",
                title: "A New Paper on Retrieval Practice",
                subtitle: "example.com",
                sourceType: "article",
                daysAgo: 0
            ),
            source(
                id: "picard-paper",
                title: "Picard Lab technical paper",
                subtitle: "journal.example",
                sourceType: "paper",
                daysAgo: 0
            )
        ]

        let utterance = "quiz me about the latest martin picard substack article"
        let resolution = MobileVoiceSourceResolver.resolve(
            sourceID: nil,
            utterance: utterance,
            sources: sources,
            currentSourceID: nil,
            activeVoiceSourceID: nil
        )

        #expect(resolution.strategy == .none)
        #expect(resolution.sourceID == nil)
    }

    @Test("Honors explicit source IDs before keyword matching")
    func honorsExplicitID() {
        let sources = [
            source(id: "a", title: "Martin Picard", subtitle: "substack.com", sourceType: "article", daysAgo: 0),
            source(id: "b", title: "Other", subtitle: nil, sourceType: "article", daysAgo: 1)
        ]

        let resolution = MobileVoiceSourceResolver.resolve(
            sourceID: "b",
            utterance: "quiz me about martin picard",
            sources: sources,
            currentSourceID: nil,
            activeVoiceSourceID: nil
        )

        #expect(resolution.strategy == .explicitID)
        #expect(resolution.sourceID == "b")
    }

    @Test("Planner and resolver micro-benchmark stays bounded for a driving utterance")
    func plannerAndResolverMicroBenchmark() {
        let utterance = "quiz me about the latest martin picard substack article"
        let sources = (0..<250).map { index in
            source(
                id: "source-\(index)",
                title: index == 249 ? "Martin Picard: Latest Substack Article" : "Source \(index)",
                subtitle: index == 249 ? "martinpicard.substack.com" : "example.com",
                sourceType: "article",
                daysAgo: 250 - index
            )
        }
        let sourceText = Array(repeating: "Mitochondria communicate stress signals through metabolic and inflammatory pathways.", count: 1_000)
            .joined(separator: "\n\n")

        let start = Date()
        let resolution = MobileVoiceSourceResolver.resolve(
            sourceID: nil,
            utterance: utterance,
            sources: sources,
            currentSourceID: nil,
            activeVoiceSourceID: nil
        )
        let prompt = DrivingSourceAnswerPlanner.makePrompt(
            DrivingSourceAnswerRequest(
                sourceTitle: "Martin Picard: Latest Substack Article",
                sourceText: sourceText,
                question: "What is the main idea?",
                recentMessages: []
            )
        )
        let elapsed = MobileBenchmarkClock.milliseconds(since: start)

        #expect(resolution.sourceID == nil)
        #expect(prompt.contextCharacterCount <= DrivingSourceAnswerPlanner.maxSourceCharacters)
        // This is intentionally generous: it catches accidental O(n^2) prompt work
        // without making unit tests sensitive to CI machine variance.
        #expect(elapsed < 100.0)
    }

    @Test("External book listening resolves exact chapter order without guessing identity")
    func externalBookActivityResolution() throws {
        // Typed: Xcode 27 infers `Int?` from `sequenceNumber:` otherwise, and
        // the ids would read "chapter-Optional(1)".
        let chapters = (1...5).map { (number: Int) in
            ExternalActivitySourceDescriptor(
                id: "chapter-\(number)",
                title: "Chapter \(number)",
                sourceType: "book",
                parentGroupID: "book-1",
                groupTitle: "Book XYZ",
                sequenceNumber: number
            )
        }
        #expect(try ExternalActivitySourceResolver.resolve(
            sourceIDs: [],
            bookTitle: "Book XYZ",
            chapterStart: 1,
            chapterEnd: 4,
            catalog: chapters
        ) == ["chapter-1", "chapter-2", "chapter-3", "chapter-4"])
        #expect(throws: ExternalActivityResolutionError.missingChapters("Book XYZ", [6])) {
            try ExternalActivitySourceResolver.resolve(
                sourceIDs: [],
                bookTitle: "Book XYZ",
                chapterStart: 4,
                chapterEnd: 6,
                catalog: chapters
            )
        }
        #expect(throws: ExternalActivityResolutionError.chooseOneIdentityMode) {
            try ExternalActivitySourceResolver.resolve(
                sourceIDs: ["chapter-1"],
                bookTitle: "Book XYZ",
                chapterStart: 1,
                chapterEnd: 1,
                catalog: chapters
            )
        }
    }

    @Test("Mobile OpenRouter requests use the same cache contract")
    func mobileOpenRouterPromptCaching() throws {
        let route = ResolvedAITextRoute(
            task: .chat,
            provider: "OpenRouter",
            model: "anthropic/claude-opus-4.8"
        )
        let request = try MobileOpenRouterChat.request(
            route: route,
            system: "stable source and instructions",
            messages: [
                (role: "user", content: "opening question"),
                (role: "assistant", content: "first answer"),
                (role: "user", content: "follow-up"),
            ],
            maxTokens: 500
        )
        #expect(request.value(forHTTPHeaderField: "X-ForeverLM-Task") == AITask.chat.rawValue)
        #expect(request.value(forHTTPHeaderField: "X-ForeverLM-Activity-ID")?.isEmpty == false)
        let data = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sessionID = try #require(payload["session_id"] as? String)
        #expect(sessionID.hasPrefix("flm-"))
        #expect(sessionID.count <= 256)

        let messages = try #require(payload["messages"] as? [[String: Any]])
        let systemBlocks = try #require(messages[0]["content"] as? [[String: Any]])
        let systemMarker = try #require(systemBlocks[0]["cache_control"] as? [String: Any])
        #expect(systemMarker["ttl"] as? String == "1h")
        let lastBlocks = try #require(messages.last?["content"] as? [[String: Any]])
        #expect(lastBlocks.last?["cache_control"] != nil)

        let repeatRequest = try MobileOpenRouterChat.request(
            route: route,
            system: "stable source and instructions",
            messages: [
                (role: "user", content: "opening question"),
                (role: "assistant", content: "a changed answer"),
                (role: "user", content: "a changed follow-up"),
            ],
            maxTokens: 500
        )
        let repeatData = try #require(repeatRequest.httpBody)
        let repeatPayload = try #require(JSONSerialization.jsonObject(with: repeatData) as? [String: Any])
        #expect(repeatPayload["session_id"] as? String == sessionID)
    }

    @Test("Mobile automatic-cache models stay unannotated but sticky")
    func mobileAutomaticPromptCaching() throws {
        let request = try MobileOpenRouterChat.request(
            route: ResolvedAITextRoute(
                task: .mobileVoiceAgent,
                provider: "OpenRouter",
                model: "openai/gpt-4o-mini"
            ),
            system: "instructions",
            messages: [(role: "user", content: "question")],
            maxTokens: 100
        )
        let data = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(payload["messages"] as? [[String: Any]])
        #expect(messages[0]["content"] as? String == "instructions")
        #expect(payload["session_id"] != nil)
    }

    @Test("Mobile text reaches only OpenRouter; any other route is refused")
    func mobileFirstPartyTextRoutesAreRefused() {
        // The labs' own hosts carry media, never text. A route naming one is a
        // resolver bug, and it fails here instead of reaching the lab's API.
        // Ramp Router, removed on 2026-09-23, is refused the same way.
        for provider in [AIProvider.anthropic, .openai, .gemini, .meta, .xai].map(\.rawValue) + ["Ramp Router"] {
            #expect(throws: (any Error).self) {
                try MobileOpenRouterChat.request(
                    route: ResolvedAITextRoute(
                        task: .chat,
                        provider: provider,
                        model: "any-model"
                    ),
                    system: "instructions",
                    messages: [(role: "user", content: "question")],
                    maxTokens: 100
                )
            }
        }
    }

    @Test("The hands-free review quiz never ends without the learner's explicit request")
    func mobileReviewClosureRequiresLearnerRequest() throws {
        let legacy = MobileVoiceReviewPromptContract.legacyInstructions(
            sourceTitle: "Test source",
            topic: "Test topic",
            sourceText: "Test source text"
        )

        #expect(legacy.contains("complete must remain false"))
        #expect(legacy.contains("Continue for as many turns or hours as the learner wants"))
        #expect(legacy.contains("never say goodbye or tell the learner they are done"))
        #expect(!legacy.contains("Run about four to six exchanges"))
    }

    private func source(
        id: String,
        title: String,
        subtitle: String?,
        sourceType: String,
        daysAgo: Int
    ) -> MobileCloudSource {
        MobileCloudSource(
            id: id,
            title: title,
            subtitle: subtitle,
            sourceType: sourceType,
            dateAdded: Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date(),
            hasAudio: true,
            isArchived: false
        )
    }

}

@Suite("iPhone pre-generated review guides")
struct MobilePaperReviewGuideTests {
    private let cleanedText = "Clean canonical paper body without headers or references."

    private func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    @Test("Encrypted Source payload projection retains the pre-generated guide")
    func parsesSyncedGuide() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "article": ["id": "paper-1", "title": "Mechanisms of Learning"],
            "sourceReviewGuide": [
                "sourceSHA256": sha256(cleanedText),
                "guide": "Question 1: GUIDE-SENTINEL",
                "generatorVersion": 3,
                "generatedAt": 1234,
            ],
        ])

        let parsed = try #require(MobileSourceReviewGuidePayloadParser.reviewGuide(from: data))
        #expect(parsed.sourceSHA256 == sha256(cleanedText))
        #expect(parsed.guide.contains("GUIDE-SENTINEL"))
        #expect(parsed.generatorVersion == 3)
    }

    @Test("Encrypted Source payload projection retains vision-analyzed paper figures")
    func parsesSyncedPaperFigures() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "paperFigures": [[
                "id": "fig-2",
                "sourceID": "paper-1",
                "figureLabel": "Figure 2",
                "pageIndex": 3,
                "caption": "Figure 2 | Treatment response.",
                "analysis": [
                    "summary": "Treatment separates from control.",
                    "visualEvidence": ["The blue line rises."],
                    "figureRect": ["x": 0.1, "y": 0.2, "width": 0.8, "height": 0.6],
                    "panels": [],
                    "analysisVersion": 1,
                    "generatedAt": 1234,
                ],
            ]],
        ])

        let figure = try #require(MobilePaperFigurePayloadParser.figures(from: data).first)
        #expect(figure.id == "fig-2")
        #expect(figure.pageNumber == 4)
        #expect(figure.analysis?.figureRect?.isValid == true)
        #expect(figure.analysis?.visualEvidence == ["The blue line rises."])
    }
}

// Lives here rather than in its own file because the Mac unit-test target
// (project.yml) compiles individual iOS voice files plus this existing test
// file; MobileNotebookCatalogParser ships in MobileCloudSourceModels.swift,
// which both this bundle and the phone already build.
@Suite("Mobile notebook catalog parser")
struct MobileNotebookCatalogParserTests {

    @Test("Parses a Mac Notebook payload into the approved pool, in order, deduplicated")
    func parsesApprovedPool() throws {
        var notebookGoal = goal(
            items: [
                item(sourceID: "seed-1", reviewState: nil),
                item(sourceID: "approved-2", reviewState: "approved"),
                item(sourceID: "pending-3", reviewState: "pending"),
                item(sourceID: "rejected-4", reviewState: "rejected"),
                item(sourceID: "seed-1", reviewState: "approved")
            ]
        )
        notebookGoal["relatedNotebookIDs"] = ["gdf15", "phenotyping", "gdf15", "proj-1", ""]
        let payload = payload(goal: notebookGoal)

        let notebook = try #require(MobileNotebookCatalogParser.notebook(fromPayloadData: payload))
        #expect(notebook.id == "proj-1")
        #expect(notebook.title == "Mitochondrial Transplantation")
        #expect(notebook.sourceIDs == ["seed-1", "approved-2"])
        #expect(notebook.contextSourceIDs == notebook.sourceIDs)
        #expect(notebook.relatedNotebookIDs == ["gdf15", "phenotyping"])
        #expect(notebook.instructions == "Focus on transplantation efficacy.")
        #expect(!notebook.isArchived)
    }

    @Test("Notebook source pool remaps a foreign source ID by portable identity")
    func remapsNotebookSourceIdentity() throws {
        let data = payload(
            goal: goal(items: [item(sourceID: "remote-source", reviewState: "approved")]),
            sourceIdentities: [[
                "sourceID": "remote-source",
                "publishedDOI": "10.1000/ABC",
            ]]
        )
        let notebook = try #require(MobileNotebookCatalogParser.notebook(fromPayloadData: data))
        let identities = MobileNotebookCatalogParser.sourceIdentities(fromPayloadData: data)
        var canonical = source(id: "local-source", title: "Canonical paper")
        canonical.publishedDOI = "10.1000/abc"

        let remapped = MobileNotebookSourceIdentityResolver.remap(
            notebook: notebook,
            identities: identities,
            sources: [canonical],
            normalizeURL: { $0 }
        )
        #expect(remapped.sourceIDs == ["local-source"])
        #expect(identities.map(\.sourceID) == ["remote-source"])
    }

    @Test("Rejects plain Schedules and Goals, nested in a Notebook or standing on their own")
    func rejectsNonNotebooks() throws {
        let schedule = payload(goal: goal(kind: nil))
        #expect(MobileNotebookCatalogParser.notebook(fromPayloadData: schedule) == nil)

        let childGoal = payload(goal: goal(parentNotebookID: "parent-1", endAt: 804_556_800))
        #expect(MobileNotebookCatalogParser.notebook(fromPayloadData: childGoal) == nil)

        // A dated parentless record is a standalone Goal on every Mac since
        // schema 120; the phone listed it as a notebook until 2026-10-02.
        let standaloneGoal = payload(goal: goal(endAt: 807_148_800))
        #expect(MobileNotebookCatalogParser.notebook(fromPayloadData: standaloneGoal) == nil)

        // Open-ended and parented is neither a Notebook nor a Goal on the Mac.
        let openChild = payload(goal: goal(parentNotebookID: "parent-1"))
        #expect(MobileNotebookCatalogParser.notebook(fromPayloadData: openChild) == nil)

        // A payload with no endAt does not decode on the Mac at all.
        var undated = goal()
        undated.removeValue(forKey: "endAt")
        #expect(MobileNotebookCatalogParser.notebook(fromPayloadData: payload(goal: undated)) == nil)

        // Whitespace-only parents are top-level Notebooks, matching the Mac's rule.
        let whitespaceParent = payload(goal: goal(parentNotebookID: "  "))
        #expect(MobileNotebookCatalogParser.notebook(fromPayloadData: whitespaceParent) != nil)
    }

    @Test("The phone's notebook rule is the Mac's, record for record")
    func notebookRuleMatchesTheMac() throws {
        let now = Date(timeIntervalSinceReferenceDate: 812_000_000)
        let deadline = Calendar.current.date(byAdding: .day, value: 30, to: now)!
        let cases: [(kind: String?, parent: String?, endAt: Date, isNotebook: Bool)] = [
            (LearningGoalRecord.companionKind, nil, LearningGoalRecord.openEndedEndAt, true),
            (LearningGoalRecord.companionKind, nil, deadline, false),
            (LearningGoalRecord.companionKind, " ", LearningGoalRecord.openEndedEndAt, true),
            (LearningGoalRecord.companionKind, "nb", deadline, false),
            (LearningGoalRecord.companionKind, "nb", LearningGoalRecord.openEndedEndAt, false),
            (LearningGoalRecord.companionKind, nil, LearningGoalRecord.openEndedThreshold, true),
            (LearningGoalRecord.companionKind, nil, LearningGoalRecord.openEndedThreshold.addingTimeInterval(-1), false),
            (nil, nil, LearningGoalRecord.openEndedEndAt, false),
        ]
        for (index, entry) in cases.enumerated() {
            let record = LearningGoalRecord(
                id: "goal-\(index)",
                title: "Case \(index)",
                startAt: now,
                endAt: entry.endAt,
                createdAt: now,
                updatedAt: now,
                status: "active",
                items: [],
                kind: entry.kind,
                parentNotebookID: entry.parent
            )
            let data = try JSONEncoder().encode(CloudKitLearningGoalPayload(goal: record))
            let parsed = MobileNotebookCatalogParser.notebook(fromPayloadData: data)
            #expect(record.isNotebook == entry.isNotebook, "case \(index)")
            #expect((parsed != nil) == entry.isNotebook, "case \(index)")
            #expect(record.isGoal == (entry.kind != nil && entry.endAt < LearningGoalRecord.openEndedThreshold), "case \(index)")
        }
        // The Portable constants are the Mac's published dates.
        #expect(LearningGoalRecord.openEndedEndAt == Date(timeIntervalSince1970: 4_102_444_800))
        #expect(LearningGoalRecord.openEndedThreshold == Date(timeIntervalSince1970: 4_000_000_000))
        #expect(MobileLearningGoalPayloadShape.openEndedEndAt == LearningGoalRecord.openEndedEndAt.timeIntervalSinceReferenceDate)
    }

    @Test("Carries the archived flag so the catalog can drop archived Notebooks")
    func flagsArchived() throws {
        let archived = payload(goal: goal(status: "archived"))
        let notebook = try #require(MobileNotebookCatalogParser.notebook(fromPayloadData: archived))
        #expect(notebook.isArchived)
    }

    @Test("Blank instructions read as nil, and both date epochs decode")
    func normalizesOptionalFields() throws {
        let blankDescription = payload(goal: goal(description: "   "))
        let notebook = try #require(MobileNotebookCatalogParser.notebook(fromPayloadData: blankDescription))
        #expect(notebook.instructions == nil)

        // JSONEncoder's default date is seconds since 2001; older payloads
        // carried Unix seconds. 2026-07-01 in both epochs must land in 2026.
        let referenceEpoch = payload(goal: goal(updatedAt: 804_556_800))
        let unixEpoch = payload(goal: goal(updatedAt: 1_782_864_000))
        let calendar = Calendar(identifier: .gregorian)
        for data in [referenceEpoch, unixEpoch] {
            let parsed = try #require(MobileNotebookCatalogParser.notebook(fromPayloadData: data))
            #expect(calendar.component(.year, from: parsed.updatedAt) == 2026)
        }
    }

    @Test("A malformed payload parses to nil rather than trapping")
    func toleratesMalformedPayloads() {
        #expect(MobileNotebookCatalogParser.notebook(fromPayloadData: Data("not json".utf8)) == nil)
        #expect(MobileNotebookCatalogParser.notebook(fromPayloadData: Data("{}".utf8)) == nil)
    }

    private func source(id: String, title: String) -> MobileCloudSource {
        MobileCloudSource(
            id: id,
            title: title,
            subtitle: nil,
            sourceType: "paper",
            dateAdded: .distantPast,
            hasAudio: false,
            isArchived: false
        )
    }

    /// A notebook by default: the Mac stores the 2100-01-01 sentinel as its
    /// `endAt`, and a real deadline makes the record a Goal.
    private func goal(
        kind: String? = "companion",
        parentNotebookID: String? = nil,
        endAt: Double = MobileLearningGoalPayloadShape.openEndedEndAt,
        status: String = "active",
        description: String? = "Focus on transplantation efficacy.",
        updatedAt: Double = 804_556_800,
        items: [[String: Any]] = []
    ) -> [String: Any] {
        var goal: [String: Any] = [
            "id": "proj-1",
            "title": "Mitochondrial Transplantation",
            "startAt": updatedAt,
            "endAt": endAt,
            "createdAt": updatedAt,
            "updatedAt": updatedAt,
            "status": status,
            "items": items
        ]
        if let kind { goal["kind"] = kind }
        if let parentNotebookID { goal["parentNotebookID"] = parentNotebookID }
        if let description { goal["description"] = description }
        return goal
    }

    private func item(sourceID: String, reviewState: String?) -> [String: Any] {
        var item: [String: Any] = [
            "id": "item-\(sourceID)",
            "goalID": "proj-1",
            "sourceID": sourceID,
            "addedAt": 804_556_800.0
        ]
        if let reviewState { item["reviewState"] = reviewState }
        return item
    }

    private func payload(
        goal: [String: Any],
        sourceIdentities: [[String: Any]] = []
    ) -> Data {
        (try? JSONSerialization.data(withJSONObject: [
            "goal": goal,
            "sourceIdentities": sourceIdentities,
        ])) ?? Data()
    }
}

@Suite("Mobile schedule catalog parser")
struct MobileScheduleCatalogParserTests {

    @Test("Parses a shared placement with ordered goal relationships and completion state")
    func parsesScheduledSource() throws {
        let payload = schedulePayload(
            plannedAt: 804_556_800,
            completedAt: 804_560_400,
            goalIDs: ["goal-a", "goal-b", "goal-a"]
        )

        let scheduled = try #require(
            MobileScheduledSourceCatalogParser.scheduledSource(fromPayloadData: payload)
        )
        #expect(scheduled.id == "placement-1")
        #expect(scheduled.sourceID == "source-1")
        #expect(scheduled.goalIDs == ["goal-a", "goal-b"])
        #expect(scheduled.isCompleted)
        #expect(Calendar(identifier: .gregorian).component(.year, from: scheduled.plannedAt) == 2026)
    }

    @Test("Accepts legacy Unix dates and optional relationships")
    func acceptsLegacyShape() throws {
        let payload = schedulePayload(
            plannedAt: 1_782_864_000,
            completedAt: nil,
            goalIDs: nil
        )

        let scheduled = try #require(
            MobileScheduledSourceCatalogParser.scheduledSource(fromPayloadData: payload)
        )
        #expect(scheduled.goalIDs.isEmpty)
        #expect(!scheduled.isCompleted)
        #expect(Calendar(identifier: .gregorian).component(.year, from: scheduled.plannedAt) == 2026)
    }

    @Test("Schedule placement remaps a missing device source ID by portable DOI")
    func remapsPortableSourceRelationshipAfterOutOfOrderDelivery() throws {
        let payload = schedulePayload(
            plannedAt: 804_556_800,
            completedAt: nil,
            goalIDs: ["goal-a"],
            sourceIdentity: [
                "sourceID": "source-1",
                "publishedDOI": "10.1000/ABC",
            ]
        )
        let scheduled = try #require(
            MobileScheduledSourceCatalogParser.scheduledSource(fromPayloadData: payload)
        )
        #expect(scheduled.sourceID == "source-1")
        #expect(scheduled.sourceIdentity?.publishedDOI == "10.1000/ABC")

        // Before Source delivery the foreign ID stays unresolved and the row is
        // hidden. Rebuilding the projection after the canonical Source arrives
        // resolves the same placement without rewriting CloudKit identity.
        let emptyIndex = MobileMemorySourceIdentityResolver.Index(
            sources: [],
            normalizeURL: { $0 }
        )
        #expect(emptyIndex.resolvedSourceID(
            scheduled.sourceID,
            identity: scheduled.sourceIdentity
        ) == "source-1")

        var canonical = MobileCloudSource(
            id: "local-source",
            title: "Canonical paper",
            subtitle: nil,
            sourceType: "paper",
            dateAdded: Date(timeIntervalSinceReferenceDate: 0),
            hasAudio: false,
            isArchived: false
        )
        canonical.publishedDOI = "10.1000/abc"
        let resolvedIndex = MobileMemorySourceIdentityResolver.Index(
            sources: [canonical],
            normalizeURL: { $0 }
        )
        #expect(resolvedIndex.resolvedSourceID(
            scheduled.sourceID,
            identity: scheduled.sourceIdentity
        ) == "local-source")
    }

    @Test("Parses plain goals for Schedule labels without treating them as Notebooks")
    func parsesGoalLabel() throws {
        let goalPayload: [String: Any] = [
            "id": "goal-a",
            "title": "Cell Biology",
            "status": "done",
            "updatedAt": 804_556_800.0
        ]
        let data = try JSONSerialization.data(withJSONObject: ["goal": goalPayload])

        let goal = try #require(MobileGoalCatalogParser.goal(fromPayloadData: data))
        #expect(goal.id == "goal-a")
        #expect(goal.title == "Cell Biology")
        #expect(!goal.isActive)
        #expect(MobileNotebookCatalogParser.notebook(fromPayloadData: data) == nil)
    }

    @Test("Rejects malformed or identity-free placements")
    func rejectsMalformedPlacements() throws {
        #expect(MobileScheduledSourceCatalogParser.scheduledSource(fromPayloadData: Data("bad".utf8)) == nil)
        let placement: [String: Any] = ["id": "placement-1", "plannedAt": 804_556_800.0]
        let missingSource = try JSONSerialization.data(withJSONObject: [
            "placement": placement
        ])
        #expect(MobileScheduledSourceCatalogParser.scheduledSource(fromPayloadData: missingSource) == nil)
    }

    private func schedulePayload(
        plannedAt: Double,
        completedAt: Double?,
        goalIDs: [String]?,
        sourceIdentity: [String: Any]? = nil
    ) -> Data {
        var placement: [String: Any] = [
            "id": "placement-1",
            "sourceID": "source-1",
            "plannedAt": plannedAt,
            "addedAt": plannedAt,
            "createdAt": plannedAt,
            "updatedAt": plannedAt
        ]
        if let completedAt { placement["completedAt"] = completedAt }
        var object: [String: Any] = ["placement": placement]
        if let goalIDs { object["goalIDs"] = goalIDs }
        if let sourceIdentity { object["sourceIdentity"] = sourceIdentity }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}

@Suite("Mobile source type grouping")
struct MobileSourceTypeGroupingTests {

    @Test("Learning materials lead in curated order; unknown types trail alphabetically")
    func ordersSections() {
        let sources = ["zine", "video", "paper", "alien", "book"].map { type in
            MobileCloudSource(
                id: type,
                title: type,
                subtitle: nil,
                sourceType: type,
                dateAdded: Date(timeIntervalSinceReferenceDate: 0),
                hasAudio: false,
                isArchived: false
            )
        }

        let labels = MobileSourceTypeGrouping.groups(for: sources).map(\.label)
        #expect(labels == ["Papers", "Books", "YouTube", "Alien", "Zine"])
    }

    @Test("Groups keep the incoming order within each section and split nothing away")
    func preservesOrderWithinGroups() {
        let sources = [
            ("new-paper", "paper", 300.0),
            ("podcast-1", "podcast", 250.0),
            ("old-paper", "paper", 100.0),
        ].map { id, type, seconds in
            MobileCloudSource(
                id: id,
                title: id,
                subtitle: nil,
                sourceType: type,
                dateAdded: Date(timeIntervalSinceReferenceDate: seconds),
                hasAudio: false,
                isArchived: false
            )
        }

        let groups = MobileSourceTypeGrouping.groups(for: sources)
        #expect(groups.map(\.label) == ["Papers", "Podcasts"])
        #expect(groups[0].sources.map(\.id) == ["new-paper", "old-paper"])
        #expect(groups.flatMap(\.sources).count == sources.count)
    }

    @Test("Known types read as catalog labels, unknown ones fall back to capitalization")
    func labelsSourceTypes() {
        #expect(MobileSourceTypeGrouping.label(for: "xpost") == "X")
        #expect(MobileSourceTypeGrouping.label(for: "meeting") == "Meetings")
        #expect(MobileSourceTypeGrouping.label(for: "webinar") == "Webinar")
    }
}

@Suite("Mobile source visibility")
struct MobileSourceVisibilityTests {

    private func source(
        id: String,
        sourceType: String = "article",
        subtitle: String? = nil,
        parentGroup: String? = nil,
        isHidden: Bool = false,
        visibleOverride: Bool = false,
        visibleYouTubeOverride: Bool = false
    ) -> MobileCloudSource {
        MobileCloudSource(
            id: id,
            title: id,
            subtitle: subtitle,
            sourceType: sourceType,
            dateAdded: Date(timeIntervalSinceReferenceDate: 0),
            hasAudio: false,
            isArchived: false,
            parentGroup: parentGroup,
            isHidden: isHidden,
            visiblePodcastEpisodeOverride: visibleOverride,
            visibleYouTubeVideoOverride: visibleYouTubeOverride
        )
    }

    @Test("The per-source hidden flag hides any type")
    func perSourceFlagHides() {
        let collections = MobileCatalogCollections.empty
        #expect(MobileSourceVisibility.isHidden(source(id: "a", isHidden: true), collections: collections))
        #expect(!MobileSourceVisibility.isHidden(source(id: "b"), collections: collections))
    }

    @Test("A hidden show hides its episodes, except ones overridden visible")
    func hiddenShowHidesEpisodes() {
        var collections = MobileCatalogCollections.empty
        collections.hiddenPodcastShowNames = ["Huberman Lab"]

        let hiddenEpisode = source(id: "ep-1", sourceType: "podcast", subtitle: "Huberman Lab")
        let overriddenEpisode = source(id: "ep-2", sourceType: "podcast", subtitle: "Huberman Lab", visibleOverride: true)
        let otherShowEpisode = source(id: "ep-3", sourceType: "podcast", subtitle: "Lex Fridman Podcast")
        // The show-name match is podcast-only, exactly like the Mac's rule: an
        // article whose domain collides with a hidden show name stays visible.
        let collidingArticle = source(id: "art-1", sourceType: "article", subtitle: "Huberman Lab")

        #expect(MobileSourceVisibility.isHidden(hiddenEpisode, collections: collections))
        #expect(!MobileSourceVisibility.isHidden(overriddenEpisode, collections: collections))
        #expect(!MobileSourceVisibility.isHidden(otherShowEpisode, collections: collections))
        #expect(!MobileSourceVisibility.isHidden(collidingArticle, collections: collections))
    }

    @Test("A hidden YouTube channel hides its videos, except ones overridden visible")
    func hiddenYouTubeChannelHidesVideos() {
        var collections = MobileCatalogCollections.empty
        collections.hiddenYouTubeChannelNames = ["3Blue1Brown"]

        let hiddenVideo = source(id: "video-1", sourceType: "video", subtitle: "3Blue1Brown")
        let overriddenVideo = source(
            id: "video-2",
            sourceType: "video",
            subtitle: "3Blue1Brown",
            visibleYouTubeOverride: true
        )
        let collidingArticle = source(id: "article-1", subtitle: "3Blue1Brown")

        #expect(MobileSourceVisibility.isHidden(hiddenVideo, collections: collections))
        #expect(!MobileSourceVisibility.isHidden(overriddenVideo, collections: collections))
        #expect(!MobileSourceVisibility.isHidden(collidingArticle, collections: collections))
    }

    @Test("A hidden course hides its lectures; hidden meeting series hide their artifacts")
    func hiddenGroupsHideMembers() {
        var collections = MobileCatalogCollections.empty
        collections.coursesByID = [
            "course-1": MobileCloudCourse(id: "course-1", title: "6.006", institution: nil, isHidden: true),
            "course-2": MobileCloudCourse(id: "course-2", title: "CS50", institution: nil, isHidden: false),
        ]
        collections.hiddenMeetingGroupIDs = ["standup"]

        #expect(MobileSourceVisibility.isHidden(source(id: "lec-1", sourceType: "course", parentGroup: "course-1"), collections: collections))
        #expect(!MobileSourceVisibility.isHidden(source(id: "lec-2", sourceType: "course", parentGroup: "course-2"), collections: collections))
        #expect(!MobileSourceVisibility.isHidden(source(id: "lec-3", sourceType: "course"), collections: collections))
        #expect(MobileSourceVisibility.isHidden(source(id: "meet-1", sourceType: "meeting", parentGroup: "standup"), collections: collections))
        #expect(!MobileSourceVisibility.isHidden(source(id: "meet-2", sourceType: "meeting", parentGroup: "retro"), collections: collections))
    }
}

@Suite("Mobile paywall shelf")
struct MobilePaywallShelfTests {

    private func source(
        id: String,
        sourceType: String = "paper",
        isPaywalled: Bool = false
    ) -> MobileCloudSource {
        MobileCloudSource(
            id: id,
            title: id,
            subtitle: nil,
            sourceType: sourceType,
            dateAdded: Date(timeIntervalSinceReferenceDate: 0),
            hasAudio: false,
            isArchived: false,
            isPaywalled: isPaywalled
        )
    }

    @Test("The column and the legacy error-message sentinel both mark a paywall")
    func foldsBothMarkers() {
        #expect(MobilePaywallShelf.isPaywalled(column: true, errorMessage: nil))
        #expect(MobilePaywallShelf.isPaywalled(column: nil, errorMessage: "paywall"))
        #expect(MobilePaywallShelf.isPaywalled(column: false, errorMessage: "paywall"))
        #expect(!MobilePaywallShelf.isPaywalled(column: nil, errorMessage: nil))
        #expect(!MobilePaywallShelf.isPaywalled(column: false, errorMessage: nil))
    }

    @Test("A genuine error message is not a paywall marker")
    func genuineErrorIsNotAPaywall() {
        #expect(!MobilePaywallShelf.isPaywalled(column: nil, errorMessage: "Download failed: paywall suspected"))
        #expect(!MobilePaywallShelf.isPaywalled(column: nil, errorMessage: "confirmPodcast"))
    }

    @Test("Browsing lists drop marked sources; the shelf is what lists them")
    func splitsBrowsableFromPaywalled() {
        let sources = [
            source(id: "readable"),
            source(id: "marked", isPaywalled: true),
            source(id: "article", sourceType: "article", isPaywalled: true),
        ]

        #expect(MobilePaywallShelf.browsable(sources).map(\.id) == ["readable"])
        #expect(MobilePaywallShelf.paywalled(sources).map(\.id) == ["marked", "article"])
    }

    @Test("The shelf is per type, so each type screen shows only its own")
    func shelfFiltersByType() {
        let sources = [
            source(id: "paper-1", isPaywalled: true),
            source(id: "article-1", sourceType: "article", isPaywalled: true),
            source(id: "paper-2"),
        ]

        #expect(MobilePaywallShelf.paywalled(sources, ofType: "paper").map(\.id) == ["paper-1"])
        #expect(MobilePaywallShelf.paywalled(sources, ofType: "article").map(\.id) == ["article-1"])
        #expect(MobilePaywallShelf.paywalled(sources, ofType: "video").isEmpty)
    }

    @Test("Order is preserved so the shelf stays newest-first like its list")
    func preservesOrder() {
        let sources = (1...5).map { source(id: "s-\($0)", isPaywalled: $0.isMultiple(of: 2)) }
        #expect(MobilePaywallShelf.paywalled(sources).map(\.id) == ["s-2", "s-4"])
        #expect(MobilePaywallShelf.browsable(sources).map(\.id) == ["s-1", "s-3", "s-5"])
    }
}

@Suite("Mobile book and course grouping")
struct MobileSourceGroupingTests {

    private func chapter(
        id: String,
        title: String,
        sourceType: String = "book",
        parentGroup: String? = nil,
        sortIndex: Int? = nil
    ) -> MobileCloudSource {
        MobileCloudSource(
            id: id,
            title: title,
            subtitle: nil,
            sourceType: sourceType,
            dateAdded: Date(timeIntervalSinceReferenceDate: 0),
            hasAudio: false,
            isArchived: false,
            parentGroup: parentGroup,
            courseSortIndex: sortIndex
        )
    }

    @Test("Chapters group under their book with the synced display title; loose sources stay standalone")
    func groupsBookChapters() {
        var collections = MobileCatalogCollections.empty
        collections.booksByID = [
            "book-1": MobileCloudBook(id: "book-1", title: "Molecular Biology of the Cell", author: "Alberts")
        ]

        let sources = [
            chapter(id: "ch-2", title: "Chapter 10", parentGroup: "book-1"),
            chapter(id: "ch-1", title: "Chapter 2", parentGroup: "book-1"),
            chapter(id: "loose", title: "Standalone Book"),
            chapter(id: "unsynced", title: "Chapter 1", parentGroup: "book-2"),
            chapter(id: "not-a-book", title: "A Paper", sourceType: "paper"),
        ]

        let result = MobileSourceGrouping.groups(ofType: "book", in: sources, collections: collections)
        #expect(result.groups.map(\.id) == ["book-2", "book-1"])
        let synced = result.groups.first { $0.id == "book-1" }
        #expect(synced?.title == "Molecular Biology of the Cell")
        #expect(synced?.subtitle == "Alberts")
        // Natural title order: Chapter 2 before Chapter 10.
        #expect(synced?.sources.map(\.id) == ["ch-1", "ch-2"])
        // A group whose Book record has not synced falls back to the raw key.
        #expect(result.groups.first { $0.id == "book-2" }?.title == "book-2")
        #expect(result.standalone.map(\.id) == ["loose"])
    }

    @Test("Explicit sort indexes lead, nils trail in natural title order")
    func ordersMembersBySortIndexThenTitle() {
        let members = [
            chapter(id: "c", title: "Lecture 3", parentGroup: "g"),
            chapter(id: "b", title: "Week 10", parentGroup: "g", sortIndex: 2),
            chapter(id: "a", title: "Week 2", parentGroup: "g", sortIndex: 1),
            chapter(id: "d", title: "Lecture 12", parentGroup: "g"),
        ]

        let result = MobileSourceGrouping.groups(ofType: "book", in: members, collections: .empty)
        #expect(result.groups.count == 1)
        #expect(result.groups[0].sources.map(\.id) == ["a", "b", "c", "d"])
    }

    @Test("Grouped types are exactly books and courses")
    func groupedTypes() {
        #expect(MobileSourceGrouping.isGroupedType("book"))
        #expect(MobileSourceGrouping.isGroupedType("course"))
        #expect(!MobileSourceGrouping.isGroupedType("podcast"))
        #expect(!MobileSourceGrouping.isGroupedType("article"))
    }
}

/// Course membership lives in the synced lecture outline, never in the member
/// sources' `parentGroup`: the Mac attaches a source to a lecture and leaves
/// its primary library home alone. Grouping courses like books therefore found
/// nothing and listed every lecture as a loose row.
@Suite("Mobile course outline grouping")
struct MobileCourseGroupingTests {

    private func source(
        id: String,
        title: String,
        sourceType: String,
        courseName: String? = nil,
        parentGroup: String? = nil
    ) -> MobileCloudSource {
        MobileCloudSource(
            id: id,
            title: title,
            subtitle: courseName,
            sourceType: sourceType,
            dateAdded: Date(timeIntervalSinceReferenceDate: 0),
            hasAudio: false,
            isArchived: false,
            parentGroup: parentGroup
        )
    }

    private func course(
        id: String,
        title: String,
        isHidden: Bool = false,
        lectures: [MobileCourseLecture] = [],
        lectureItems: [MobileCourseLectureItem] = []
    ) -> MobileCloudCourse {
        MobileCloudCourse(
            id: id,
            title: title,
            institution: nil,
            isHidden: isHidden,
            lectures: lectures,
            lectureItems: lectureItems
        )
    }

    @Test("Lecture items group under their course as one path, readings under their lecture")
    func groupsByLectureOutline() {
        var collections = MobileCatalogCollections.empty
        collections.coursesByID = [
            "cs336": course(
                id: "cs336",
                title: "CS336: Language Modeling from Scratch",
                lectures: [
                    MobileCourseLecture(id: "l2", number: 2, title: "2) PyTorch"),
                    MobileCourseLecture(id: "l1", number: 1, title: "Overview"),
                ],
                lectureItems: [
                    MobileCourseLectureItem(id: "i3", lectureID: "l2", sourceID: "vid-2", role: "video", sortIndex: 0),
                    MobileCourseLectureItem(id: "i2", lectureID: "l1", sourceID: "vid-1", role: "video", sortIndex: 1),
                    MobileCourseLectureItem(id: "i1", lectureID: "l1", sourceID: "notes-1", role: "exercise", sortIndex: 0),
                    MobileCourseLectureItem(id: "i4", lectureID: "l1", sourceID: "paper-1", role: "reading", sortIndex: 2),
                    MobileCourseLectureItem(id: "i5", lectureID: "l1", sourceID: "not-synced", role: "video", sortIndex: 3),
                ]
            )
        ]

        let sources = [
            source(id: "vid-1", title: "Lecture 1 recording", sourceType: "video"),
            source(id: "vid-2", title: "Lecture 2 recording", sourceType: "video"),
            source(id: "notes-1", title: "Assignment 1", sourceType: "course"),
            source(id: "paper-1", title: "Attention Is All You Need", sourceType: "paper"),
        ]

        let result = MobileSourceGrouping.groups(ofType: "course", in: sources, collections: collections)
        #expect(result.groups.count == 1)
        #expect(result.standalone.isEmpty)

        let group = result.groups[0]
        #expect(group.id == "cs336")
        // One path, no Papers folder: each lecture's video, then its paper,
        // then its notes, in lecture order.
        #expect(group.sections.map(\.id) == ["course"])
        #expect(group.sections[0].items.map(\.source.id) == ["vid-1", "paper-1", "notes-1", "vid-2"])
        // The Mac's numbering — already-numbered titles are left alone,
        // unnumbered ones get the prefix.
        #expect(group.sections[0].items.compactMap(\.displayTitle) == ["1) Overview", "2) PyTorch"])
        // A member that has not synced to the phone yet is skipped, not faked.
        #expect(group.sources.map(\.id) == ["vid-1", "paper-1", "notes-1", "vid-2"])
        #expect(group.memberSummary == "2 lectures · 1 reading · 1 material")
    }

    @Test("Course material no course claims is surfaced nowhere")
    func dropsMaterialNoCourseClaims() {
        var collections = MobileCatalogCollections.empty
        collections.coursesByID = [
            "sysbio": course(
                id: "sysbio",
                title: "Systems Biology",
                lectures: [MobileCourseLecture(id: "l1", number: 1, title: nil)],
                lectureItems: [
                    MobileCourseLectureItem(id: "i1", lectureID: "l1", sourceID: "vid-1", role: "video", sortIndex: 0)
                ]
            )
        ]

        let sources = [
            source(id: "vid-1", title: "Week 1", sourceType: "video"),
            source(id: "pdf-filed", title: "Handout", sourceType: "course", parentGroup: "sysbio"),
            source(id: "pdf-10", title: "worksheet10", sourceType: "course", courseName: "Math 21 B: Linear Algebra"),
            source(id: "pdf-2", title: "worksheet2", sourceType: "course", courseName: "Math 21 B: Linear Algebra"),
            source(id: "pdf-carried", title: "Handout", sourceType: "course", courseName: "Systems Biology"),
            source(id: "pdf-none", title: "Orphan", sourceType: "course"),
        ]

        let result = MobileSourceGrouping.groups(ofType: "course", in: sources, collections: collections)
        // Only the outlined course, holding only what it actually claims: its
        // lecture item and the material filed under its id.
        #expect(result.groups.map(\.title) == ["Systems Biology"])
        #expect(result.groups[0].sections.map(\.id) == ["course"])
        #expect(result.groups[0].sections[0].items.compactMap(\.displayTitle) == ["1)"])
        #expect(result.groups[0].sections[0].items.map(\.source.id) == ["vid-1", "pdf-filed"])
        // The course name a source carries is import metadata, not membership:
        // material naming a course it is not in stays out of it, and material
        // naming a course that no longer exists does not recreate one.
        #expect(result.standalone.isEmpty)
    }

    @Test("A hidden course, and one whose members have not synced, produce no row")
    func skipsHiddenAndEmptyCourses() {
        var collections = MobileCatalogCollections.empty
        collections.coursesByID = [
            "hidden": course(
                id: "hidden",
                title: "Temporary resolver group",
                isHidden: true,
                lectures: [MobileCourseLecture(id: "l1", number: 1, title: nil)],
                lectureItems: [
                    MobileCourseLectureItem(id: "i1", lectureID: "l1", sourceID: "vid-1", role: "video", sortIndex: 0)
                ]
            ),
            "empty": course(id: "empty", title: "Molecular Biology of the Cell"),
        ]

        let sources = [source(id: "vid-1", title: "Week 1", sourceType: "video")]
        let result = MobileSourceGrouping.groups(ofType: "course", in: sources, collections: collections)
        #expect(result.groups.isEmpty)
        #expect(result.standalone.isEmpty)
    }
}

@Suite("Mobile source file paths")
struct MobileSourceFilePathTests {
    @Test("Paper paths resolve below the shared iCloud content root")
    func resolvesRelativeAndAbsolutePaths() {
        #expect(MobileSourceFilePath.relativePDFPath(
            localFilePath: "Papers/research.pdf",
            url: nil
        ) == "Papers/research.pdf")
        #expect(MobileSourceFilePath.relativePDFPath(
            localFilePath: "/Users/reader/Library/Mobile Documents/iCloud~com~foreverlm/Documents/ForeverLM/Papers/research.pdf",
            url: nil
        ) == "Papers/research.pdf")
        #expect(MobileSourceFilePath.relativePDFPath(
            localFilePath: "/Users/reader/Library/Mobile Documents/iCloud~com~foreverlm/Documents/ForeverLM 3/Papers/research.pdf",
            url: nil
        ) == "Papers/research.pdf")
    }

    @Test("A legacy local PDF URL is used when localFilePath is absent")
    func fallsBackToURL() {
        #expect(MobileSourceFilePath.relativePDFPath(
            localFilePath: nil,
            url: "ForeverLM/Papers/legacy.pdf"
        ) == "Papers/legacy.pdf")
    }

    @Test("Remote, non-PDF, and escaping paths are rejected")
    func rejectsUnsafeOrInapplicablePaths() {
        #expect(MobileSourceFilePath.relativePDFPath(
            localFilePath: nil,
            url: "https://example.com/paper.pdf"
        ) == nil)
        #expect(MobileSourceFilePath.relativePDFPath(
            localFilePath: "Articles/paper.html",
            url: nil
        ) == nil)
        #expect(MobileSourceFilePath.relativePDFPath(
            localFilePath: "../../outside.pdf",
            url: nil
        ) == nil)
    }

    @Test("A shared PDF is named after its source's title")
    func sharedPDFFileNames() {
        #expect(MobileSourceFilePath.sharedPDFFileName(
            title: "Mitochondria: the power plants of the cell"
        ) == "Mitochondria - the power plants of the cell.pdf")
        #expect(MobileSourceFilePath.sharedPDFFileName(
            title: "TGF-β/SMAD signalling\nin fibrosis"
        ) == "TGF-β-SMAD signalling in fibrosis.pdf")
        #expect(MobileSourceFilePath.sharedPDFFileName(title: ".hidden.PDF") == "hidden.pdf")
        #expect(MobileSourceFilePath.sharedPDFFileName(title: "  \t ") == "Document.pdf")
        #expect(MobileSourceFilePath.sharedPDFFileName(
            title: String(repeating: "a", count: 300)
        ) == String(repeating: "a", count: 120) + ".pdf")
    }

    @Test("Show in Files opens the Files app on the file itself")
    func filesAppURLs() {
        let placed = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/ABC/Documents/Sleep and mitochondria.pdf")
        #expect(MobileSourceFilePath.filesAppURL(for: placed)?.absoluteString
            == "shareddocuments:///var/mobile/Containers/Data/Application/ABC/Documents/Sleep%20and%20mitochondria.pdf")
        #expect(MobileSourceFilePath.filesAppURL(for: URL(string: "https://example.com/paper.pdf")!) == nil)
    }
}
