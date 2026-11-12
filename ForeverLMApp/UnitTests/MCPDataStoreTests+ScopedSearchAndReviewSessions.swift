// MCPDataStoreTests: scoped search, read next, review sessions and chat imports.

import Testing
import AppKit
import Foundation
import PDFKit
import SQLite3
@testable import ForeverLM

#if os(macOS)

extension MCPDataStoreTests {
    // MARK: - Scoped search

    /// Scoping has to happen *inside* the index, not by filtering its output.
    /// Here the attached source is the worst match in the corpus: 200 chunks
    /// score a perfect 1.0 and it scores 0. A global top-K plus a post-filter
    /// would return nothing at all, which is exactly how "which of my attached
    /// sources answers this?" silently returns an empty pool.
    @Test("scoped vector search ranks within the allowed sources only")
    func vectorIndexScopedSearchIgnoresTheRestOfTheCorpus() {
        let index = SourceVectorIndex(dimensions: 3)
        var vectors: [String: [Float]] = [:]
        for position in 0..<200 {
            vectors["loud-\(position)::chunk::0000"] = [1, 0, 0]
        }
        vectors["attached::chunk::0003"] = [0, 1, 0]
        index.load(vectors, sourceIDForChunk: Self.sourceIDForChunk)

        let scoped = index.search(
            queryVector: [1, 0, 0],
            topK: 5,
            threshold: 0,
            allowedSources: ["attached"]
        )
        #expect(scoped.count == 1)
        #expect(scoped.first?.id == "attached::chunk::0003")

        let unscoped = index.search(queryVector: [1, 0, 0], topK: 5, threshold: 0)
        #expect(unscoped.count == 5)
        #expect(unscoped.allSatisfy { $0.id.hasPrefix("loud-") })
    }

    @Test("unscoped vector search excludes opted-out source families before selection")
    func vectorIndexExcludesSourcesBeforeSelection() {
        let index = SourceVectorIndex(dimensions: 3)
        index.load(
            [
                "excluded::chunk::0000": [1, 0, 0],
                "included::chunk::0000": [0.8, 0.2, 0],
            ],
            sourceIDForChunk: Self.sourceIDForChunk
        )

        let hits = index.search(
            queryVector: [1, 0, 0],
            topK: 1,
            threshold: 0,
            excludedSources: ["excluded"]
        )

        #expect(hits.map(\.id) == ["included::chunk::0000"])
    }

    /// A scoped search scores a gathered copy of the allowed rows, so every
    /// score has to be mapped back to the row it came from. Getting that
    /// mapping wrong returns real scores attached to the wrong chunk ids —
    /// plausible-looking results pointing at the wrong passages.
    @Test("scoped vector search maps gathered rows back to the right chunks")
    func vectorIndexScopedSearchMapsGatheredRowsBack() {
        let index = SourceVectorIndex(dimensions: 3)
        var vectors: [String: [Float]] = [:]
        for position in 0..<50 {
            vectors["other-\(position)::chunk::0000"] = [1, 0, 0]
        }
        vectors["a::chunk::0000"] = [0.9, 0.1, 0]
        vectors["a::chunk::0001"] = [0.2, 0.9, 0]
        vectors["b::chunk::0000"] = [0.5, 0.5, 0]
        index.load(vectors, sourceIDForChunk: Self.sourceIDForChunk)

        let hits = index.search(
            queryVector: [1, 0, 0],
            topK: 3,
            threshold: 0,
            allowedSources: ["a", "b"]
        )

        #expect(hits.count == 3)
        #expect(hits.first?.id == "a::chunk::0000")
        #expect(Set(hits.map(\.id)) == ["a::chunk::0000", "a::chunk::0001", "b::chunk::0000"])
    }

    @Test("scoped vector search returns nothing when no allowed source is indexed")
    func vectorIndexScopedSearchWithNoMatchingSource() {
        let index = SourceVectorIndex(dimensions: 3)
        index.load(["known::chunk::0000": [1, 0, 0]], sourceIDForChunk: Self.sourceIDForChunk)

        let hits = index.search(
            queryVector: [1, 0, 0],
            topK: 5,
            threshold: 0,
            allowedSources: ["absent"]
        )
        #expect(hits.isEmpty)
    }

    @Test("a source's centroid is the unit mean of its chunk rows")
    func vectorIndexCentroidsAverageEachSourcesChunks() {
        let index = SourceVectorIndex(dimensions: 3)
        index.load(
            [
                "a::chunk::0000": [2, 0, 0],
                "a::chunk::0001": [0, 5, 0],
                "b::chunk::0000": [0, 0, 1],
            ],
            sourceIDForChunk: Self.sourceIDForChunk
        )

        let centroids = index.centroids(forSources: ["a", "absent"])
        #expect(Set(centroids.keys) == ["a"])
        let a = centroids["a"] ?? []
        #expect(a.count == 3)
        // Rows are normalized before averaging, so the chunk lengths 2 and 5
        // carry no weight: the mean sits on the diagonal.
        #expect(abs(a[0] - 0.7071) < 0.001)
        #expect(abs(a[1] - 0.7071) < 0.001)
        #expect(abs(a[2]) < 0.001)
    }

    @Test("best source scores take each allowed source's best chunk against any query")
    func vectorIndexBestSourceScoresAcrossQueries() {
        let index = SourceVectorIndex(dimensions: 3)
        index.load(
            [
                "a::chunk::0000": [1, 0, 0],
                "a::chunk::0001": [0, 0, 1],
                "b::chunk::0000": [0, 1, 0],
                "outside::chunk::0000": [1, 0, 0],
            ],
            sourceIDForChunk: Self.sourceIDForChunk
        )

        let best = index.bestSourceScores(
            queries: [[0, 1, 0], [0, 0, 1]],
            allowedSources: ["a", "b"]
        )
        #expect(Set(best.keys) == ["a", "b"])
        #expect(best["a"]?.query == 1)
        #expect(abs((best["a"]?.score ?? 0) - 1) < 0.001)
        #expect(best["b"]?.query == 0)
        #expect(abs((best["b"]?.score ?? 0) - 1) < 0.001)
    }

    /// Read next measures the unread library against what was actually read:
    /// a glance does not steer it, and nothing already opened, stamped read or
    /// outside the caller's pool comes back.
    @Test("read next ranks unread sources by closeness to recent reading")
    func readNextRanksUnreadSourcesByRecentReading() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let ks = try store.knowledgeStore()
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let dimensions = StorageService.sourceEmbeddingDimensions
        let model = StorageService.sourceEmbeddingModel
        func vector(_ weights: [Int: Float]) -> [Float] {
            var values = [Float](repeating: 0, count: dimensions)
            for (axis, weight) in weights { values[axis] = weight }
            return values
        }
        func embed(_ sourceID: String, _ weights: [Int: Float]) throws {
            try ks.saveEmbedding(
                entityType: .sourceChunk,
                entityId: StorageService.sourceChunkEmbeddingId(sourceId: sourceID, index: 0),
                vector: vector(weights),
                model: model
            )
        }
        let now = Date()
        func activity(_ sourceID: String, engagedSeconds: Double) throws {
            let day = Calendar.current.startOfDay(for: now.addingTimeInterval(-86_400)).timeIntervalSinceReferenceDate
            try ks.exec("""
                INSERT INTO source_activity_days
                    (id, scheduled_source_id, source_id, day_start, first_activity_at, last_activity_at,
                     kinds, completed_kinds, max_fraction, engaged_seconds)
                VALUES ('day-\(sourceID)', 'placement-\(sourceID)', '\(sourceID)', \(day), \(day + 60), \(day + 90),
                        1, 0, 0.4, \(engagedSeconds))
            """)
        }

        try embed("read-mito", [0: 1])
        try activity("read-mito", engagedSeconds: 600)
        try embed("glanced-cars", [1: 1])
        try activity("glanced-cars", engagedSeconds: 30)

        try embed("unread-mito", [0: 0.9, 2: 0.1])
        try embed("unread-cars", [1: 1])
        try embed("not-in-pool", [0: 1])
        try insertSource(dbPath: dbPath, id: "stamped-read", title: "Stamped", content: "Already finished elsewhere.")
        // The read stamp lives in the member's reading state, not on the source row.
        try ks.writeReadingPlace(sourceID: "stamped-read", readAt: .some(now))
        try embed("stamped-read", [0: 1])

        let picks = try StorageService.readNextSuggestions(
            candidateIDs: ["unread-mito", "unread-cars", "stamped-read", "glanced-cars"],
            limit: 5,
            now: now,
            using: ks
        )

        #expect(picks.map(\.sourceID) == ["unread-mito", "unread-cars"])
        #expect(picks.first?.nearestReadSourceID == "read-mito")
    }

    @Test("read next offers nothing when nothing was read recently")
    func readNextIsEmptyWithoutRecentReading() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let ks = try store.knowledgeStore()
        try ks.saveEmbedding(
            entityType: .sourceChunk,
            entityId: StorageService.sourceChunkEmbeddingId(sourceId: "unread", index: 0),
            vector: [Float](repeating: 1, count: StorageService.sourceEmbeddingDimensions),
            model: StorageService.sourceEmbeddingModel
        )

        let picks = try StorageService.readNextSuggestions(candidateIDs: ["unread"], limit: 5, using: ks)
        #expect(picks.isEmpty)
    }

    private static func sourceIDForChunk(_ chunkID: String) -> String? {
        chunkID.range(of: "::chunk::").map { String(chunkID[chunkID.startIndex..<$0.lowerBound]) }
    }

    /// The GDF15 regression: the embedding model cannot represent a rare token (swapping
    /// GDF15 for GFRAL moves the sentence vector 0.6%), so on a rare-term query the
    /// semantic ranking is noise. An exact full-text match must still win. Here the
    /// embedding ranks the *wrong* source first and the true match dead last; the
    /// rarity-weighted fusion must still put the exact match on top.
    @Test("exact rare-term match outranks a semantically-similar-but-wrong source")
    func searchSourcesSemanticRareTermBeatsSemanticNoise() async throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        let gdf15Title = "Endothelial GDF15 deficiency enhances barrier function"
        let gdf15Body = "Endothelial cells lacking GDF15 showed improved barrier integrity."
        try insertSource(dbPath: dbPath, id: "source-gdf15", title: gdf15Title, content: gdf15Body)
        try insertFTS(dbPath: dbPath, id: "source-gdf15", title: gdf15Title, body: gdf15Body)

        let decoyTitle = "Partial Reprogramming with Yamanaka Factors"
        let decoyBody = "Cellular rejuvenation via OSKM induction and epigenetic clocks."
        try insertSource(dbPath: dbPath, id: "source-decoy", title: decoyTitle, content: decoyBody)
        try insertFTS(dbPath: dbPath, id: "source-decoy", title: decoyTitle, body: decoyBody)

        // A realistically sized corpus: "GDF15" must be genuinely rare for the rarity
        // weighting to engage, which is the whole point of the test.
        for index in 0..<58 {
            let id = "filler-\(index)"
            let title = "Unrelated source \(index)"
            let body = "General prose about compilers, history, and cardiovascular exercise."
            try insertSource(dbPath: dbPath, id: id, title: title, content: body)
            try insertFTS(dbPath: dbPath, id: id, title: title, body: body)
        }

        // The embedder is blind to "GDF15" — it ranks the decoy closest to the query and
        // the true match orthogonal to it. This is the observed real-world failure: a
        // search for "GDF15" returned "Partial Reprogramming with Yamanaka Factors".
        try insertEmbedding(dbPath: dbPath, entityId: "source-decoy", vector: [1, 0, 0])
        try insertEmbedding(dbPath: dbPath, entityId: "source-gdf15", vector: [0, 0, 1])

        let store = MCPDataStore(
            dbPath: dbPath,
            sourceEmbeddingProvider: { _ in [1, 0, 0] }
        )

        let result = try await store.searchSourcesSemantic(queryText: "GDF15", limit: 5)

        let gdf15Index = result.range(of: "Endothelial GDF15 deficiency")?.lowerBound
        let decoyIndex = result.range(of: "Partial Reprogramming")?.lowerBound
        #expect(gdf15Index != nil, "the exact GDF15 match must be returned at all")
        if let gdf15Index, let decoyIndex {
            #expect(gdf15Index < decoyIndex, "the exact match must outrank the semantic decoy")
        }
    }

    /// The rare term usually arrives wrapped in ordinary words. OR-ing the whole question
    /// into the full-text index retrieves every source containing "sources" or "have" and
    /// leans on BM25 to dig the real answer back out; the informative-term filter drops
    /// those before the query runs. Here every filler source contains the noise words and
    /// only one contains GDF15 — asking conversationally must rank the same as asking for
    /// the bare term.
    @Test("a rare term still leads when wrapped in a natural-language question")
    func searchSourcesSemanticRareTermSurvivesConversationalPhrasing() async throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        let gdf15Title = "Endothelial GDF15 deficiency enhances barrier function"
        let gdf15Body = "Endothelial cells lacking GDF15 showed improved barrier integrity."
        try insertSource(dbPath: dbPath, id: "source-gdf15", title: gdf15Title, content: gdf15Body)
        try insertFTS(dbPath: dbPath, id: "source-gdf15", title: gdf15Title, body: gdf15Body)

        // Every filler source carries the question's ordinary words, so a naive OR-ed
        // match expression retrieves all of them alongside the one real answer. The
        // corpus is sized past the rarity cutoff on purpose: GDF15 in 1 of ~121 sources
        // gives an IDF of ~4.4, which is what makes the informative-term filter engage.
        for index in 0..<120 {
            let id = "filler-\(index)"
            let title = "What sources I have on general topics \(index)"
            let body = "I have collected sources on what these general topics do and have covered."
            try insertSource(dbPath: dbPath, id: id, title: title, content: body)
            try insertFTS(dbPath: dbPath, id: id, title: title, body: body)
        }

        try insertEmbedding(dbPath: dbPath, entityId: "source-gdf15", vector: [0, 0, 1])

        let store = MCPDataStore(
            dbPath: dbPath,
            sourceEmbeddingProvider: { _ in [1, 0, 0] }
        )

        let result = try await store.searchSourcesSemantic(
            queryText: "what sources do i have on GDF15?",
            limit: 5
        )

        #expect(result.contains("Endothelial GDF15 deficiency"), "the exact GDF15 match must be returned")

        let gdf15Index = result.range(of: "Endothelial GDF15 deficiency")?.lowerBound
        let firstFillerIndex = result.range(of: "What sources I have on general topics")?.lowerBound
        if let gdf15Index, let firstFillerIndex {
            #expect(gdf15Index < firstFillerIndex, "the rare term must outrank sources matching only the question's filler words")
        }
    }

    /// A short article with the requested surname in its author field can receive a much
    /// stronger BM25 score than a long PDF matching the surname and every topic term.
    /// Targeted paper lookup must lead with constraint coverage, then use BM25 and
    /// semantic similarity only to break ties.
    @Test("a targeted paper lookup prefers author plus topic coverage over one surname hit")
    func searchSourcesSemanticPaperLookupCombinesAuthorAndTopicConstraints() async throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        let paperTitle = "Mechanism of age-related accumulation of mtDNA mutations in human blood"
        let longPaperBody = "CHIP mitochondrial DNA "
            + String(repeating: "background evidence ", count: 5_000)
            + " mutations"
        try insertSource(
            dbPath: dbPath,
            id: "gupta-mtdna-paper",
            title: paperTitle,
            content: longPaperBody,
            sourceType: "paper"
        )
        try insertFTS(
            dbPath: dbPath,
            id: "gupta-mtdna-paper",
            title: paperTitle,
            author: "Rahul Gupta",
            body: longPaperBody
        )

        let decoyTitle = "AI for Bio has a Fuzzy API problem"
        try insertSource(
            dbPath: dbPath,
            id: "ankit-gupta-decoy",
            title: decoyTitle,
            content: "A short article about machine learning for drug discovery."
        )
        try insertFTS(
            dbPath: dbPath,
            id: "ankit-gupta-decoy",
            title: decoyTitle,
            author: "Ankit Gupta",
            body: "A short article about machine learning for drug discovery."
        )

        // Keep the exact terms genuinely rare, as they are in a production-sized
        // library, and deliberately make the semantic branch prefer the wrong Gupta.
        for index in 0..<120 {
            let id = "paper-lookup-filler-\(index)"
            let title = "Unrelated source \(index)"
            let body = "General prose about compilers, history, and exercise."
            try insertSource(dbPath: dbPath, id: id, title: title, content: body)
            try insertFTS(dbPath: dbPath, id: id, title: title, body: body)
        }
        try insertEmbedding(dbPath: dbPath, entityId: "ankit-gupta-decoy", vector: [1, 0, 0])
        try insertEmbedding(dbPath: dbPath, entityId: "gupta-mtdna-paper", vector: [0, 0, 1])

        let store = MCPDataStore(
            dbPath: dbPath,
            sourceEmbeddingProvider: { _ in [1, 0, 0] }
        )
        let result = try await store.searchSourcesSemantic(
            queryText: "CHIP mitochondrial DNA mutations Gupta",
            limit: 8
        )

        let paperIndex = result.range(of: paperTitle)?.lowerBound
        let decoyIndex = result.range(of: decoyTitle)?.lowerBound
        #expect(paperIndex != nil, "the paper satisfying the author and topic constraints must be returned")
        if let paperIndex, let decoyIndex {
            #expect(paperIndex < decoyIndex, "the complete paper match must be the first Gupta result")
        }
    }

    /// "Chris Masterjohn statins criticism" once returned Chris Hemsworth's episode
    /// and missed a Masterjohn video: each matched two of the four terms, and the
    /// tie fell to the semantic branch. Between equal counts, the rarer terms win.
    @Test("a tie on constraint count goes to the source matching the rarer terms")
    func searchSourcesSemanticConstraintTieGoesToRarerTerms() async throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        let videoTitle = "Rethinking Serotonin And Depression"
        let videoBody = "Chris Masterjohn "
            + String(repeating: "background evidence ", count: 5_000)
            + " serotonin"
        try insertSource(dbPath: dbPath, id: "masterjohn-video", title: videoTitle, content: videoBody, sourceType: "video")
        try insertFTS(dbPath: dbPath, id: "masterjohn-video", title: videoTitle, body: videoBody)

        let decoyTitle = "Chris Hemsworth on longevity"
        let decoyBody = "Minimal feedback, not even constructive criticism."
        try insertSource(dbPath: dbPath, id: "hemsworth-decoy", title: decoyTitle, content: decoyBody)
        try insertFTS(dbPath: dbPath, id: "hemsworth-decoy", title: decoyTitle, body: decoyBody)

        // "masterjohn" in one source, "statins" in three, "criticism" in five and
        // "chris" in eight: every term informative, only the surname rare.
        for index in 0..<120 {
            let id = "tie-filler-\(index)"
            let title = "Unrelated source \(index)"
            let extra = switch index {
            case 0..<6: " Chris wrote this."
            case 6..<9: " It covers statins."
            case 9..<13: " A criticism of it."
            default: ""
            }
            let body = "General prose about compilers, history, and exercise." + extra
            try insertSource(dbPath: dbPath, id: id, title: title, content: body)
            try insertFTS(dbPath: dbPath, id: id, title: title, body: body)
        }
        try insertEmbedding(dbPath: dbPath, entityId: "hemsworth-decoy", vector: [1, 0, 0])
        try insertEmbedding(dbPath: dbPath, entityId: "masterjohn-video", vector: [0, 0, 1])

        let store = MCPDataStore(
            dbPath: dbPath,
            sourceEmbeddingProvider: { _ in [1, 0, 0] }
        )
        let result = try await store.searchSourcesSemantic(
            queryText: "Chris Masterjohn statins criticism",
            limit: 8
        )

        let videoIndex = result.range(of: videoTitle)?.lowerBound
        let decoyIndex = result.range(of: decoyTitle)?.lowerBound
        #expect(videoIndex != nil, "the source naming Masterjohn must be returned")
        if let videoIndex, let decoyIndex {
            #expect(videoIndex < decoyIndex, "chris + masterjohn must outrank chris + criticism")
        }
    }

    @Test("searchSourcesSemantic centers evidence on matched text")
    func searchSourcesSemanticCentersEvidenceOnMatchedText() async throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let opening = (0..<120).map { "opening\($0)" }.joined(separator: " ")
        let content = "\(opening) The author names GWAS directly here and then discusses missing heritability, polygenicity, and tiny effect sizes."

        try insertSource(
            dbPath: dbPath,
            id: "source-late-gwas",
            title: "Late Match Chapter",
            content: content
        )
        try insertEmbedding(dbPath: dbPath, entityId: "source-late-gwas", vector: [1, 0, 0])

        let store = MCPDataStore(
            dbPath: dbPath,
            sourceEmbeddingProvider: { _ in [1, 0, 0] }
        )

        let result = try await store.searchSourcesSemantic(queryText: "GWAS", limit: 5, threshold: 0.1)

        #expect(result.contains("Evidence:"))
        #expect(result.contains("GWAS directly here"))
        #expect(!result.contains("opening0 opening1 opening2"))
    }

    @Test("startReviewSession links source when topic is a quiz prompt")
    func startReviewSessionLinksSourceFromQuizPrompt() async throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        try insertSource(
            dbPath: dbPath,
            id: "source-a",
            title: "AI for Bio fuzzy API problem drug discovery",
            content: "Drug discovery source content."
        )

        let store = MCPDataStore(dbPath: dbPath)
        let started = try await store.startReviewSession(topic: "Please use ForeverLM to quiz me on this source: AI for Bio fuzzy API problem drug discovery")
        let sessions = try store.getReviewSessions(topic: nil, sourceId: "source-a")

        #expect(started.contains("(foreverlm://source/source-a)"), "the related source is its link, never a bare id")
        #expect(started.contains("Review session started: AI for Bio fuzzy API problem drug discovery"))
        #expect(started.contains("Review structure:"))
        #expect(started.contains("infer 3-7 core concepts"))
        #expect(sessions.contains("AI for Bio fuzzy API problem drug discovery"))
    }

    @Test("start_review_session operation id reuses one exact session")
    func startReviewSessionIsIdempotentByOperationID() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(
            dbPath: dbPath,
            id: "operation-review-source",
            title: "Operation review source",
            content: "A retry must address one review session."
        )

        let first = try await store.startReviewSession(
            topic: "Operation review",
            operationID: "start-call-7"
        )
        // The exact retry must replay the stored source set rather than rerun
        // topic discovery after sync adds another matching source.
        try insertSource(
            dbPath: dbPath,
            id: "operation-review-source-late",
            title: "Operation review late arrival",
            content: "This source arrived after the operation already chose its review."
        )
        let second = try await store.startReviewSession(
            topic: "Operation review",
            operationID: "start-call-7"
        )
        let sessionID = parsedSessionID(from: first)

        #expect(!sessionID.isEmpty)
        #expect(parsedSessionID(from: second) == sessionID)
        #expect(!second.contains("operation-review-source-late"))
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM review_sessions WHERE id = '\(sessionID)'"
        ) == 1)

        do {
            _ = try await store.startReviewSession(
                topic: "Changed operation review",
                operationID: "start-call-7"
            )
            Issue.record("Expected changed arguments for a reused operation_id to fail")
        } catch let error as MCPError {
            #expect(String(describing: error).contains("different start_review_session arguments"))
        }
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM review_sessions WHERE id LIKE 'mcp-review-session-operation-%'"
        ) == 1)
    }

    @Test("The server instructions and import_review_chat tell an assistant to keep a chat about sources as it goes: a new chat on the first answer, an append with session_id on every later one")
    func chatAboutSourcesIsSavedAsItGoes() throws {
        // The product owner (2026-09-20): "whenever chatting about sources in foreverlm,
        // we have to save those chats as chats in foreverlm each time … if
        // it's the first one, make a new chat, otherwise append".
        let instructions = Prompts.mcpServerInstructions
        #expect(instructions.contains("Saving a conversation about sources:"))
        #expect(instructions.contains("call import_review_chat without session_id"))
        #expect(instructions.contains("call import_review_chat again with that session_id and only the new question and answer"))
        #expect(instructions.contains("do not wait for the conversation to end"))
        #expect(instructions.contains("never import it as well"), "a live review is recorded by end_review_session, not imported twice")
        let tool = try #require(MCPToolRegistry.shared.tools.first { $0.name == "import_review_chat" })
        #expect(tool.description.contains("save the first question and answer without session_id"))
        #expect(tool.description.contains("append each later exchange with it as soon as you have answered"))

        // The product owner (2026-09-20), on a chat whose saved copy was a paraphrase
        // written before the answer: the stored chat is the chat on screen,
        // read from Claude Code's own session file where there is one.
        #expect(instructions.contains("pass transcript_file with the value of"))
        #expect(instructions.contains("CLAUDE_CODE_SESSION_ID"))
        #expect(instructions.contains("after your answer is written"))
        #expect(instructions.contains("never a summary or a shortened version"))
        #expect(tool.description.contains("pass transcript_file"))
        #expect(tool.description.contains("never a summary or a shortened version"))
        let properties = try #require(tool.inputSchema["properties"] as? [String: Any])
        #expect(properties["transcript_file"] != nil)
        #expect((tool.inputSchema["required"] as? [String]) == ["title"], "transcript is one of two ways to hand over the chat")
    }

    @Test("import_review_chat appends a later chunk to the session the first chunk made")
    func importReviewChatAppendsChunks() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(dbPath: dbPath, id: "chunk-source-a", title: "Chunk source A", content: "First chunk source.")
        try insertSource(dbPath: dbPath, id: "chunk-source-b", title: "Chunk source B", content: "Second chunk source.")

        let first = try store.importReviewChat(
            title: "Bayes in chunks",
            transcript: "Assistant: What is a prior?\nYou: Belief before evidence.",
            sourceIDs: ["chunk-source-a"],
            summary: nil,
            overallScore: nil,
            modelProvider: "Claude",
            modelID: nil
        )
        let sessionID = mcpAnswerValue("session_id", in: first) ?? ""  // the new chat's own `session_id:` line
        #expect(!sessionID.isEmpty)
        #expect(first.contains("pass session_id \(sessionID)"))

        let second = try store.importReviewChat(
            title: "A different title that must not win",
            transcript: "Assistant: And a posterior?\nYou: Belief after evidence.\nAssistant: Good. Likelihood?\nYou: How well the data fit a hypothesis.",
            sourceIDs: ["chunk-source-b"],
            summary: "Covered prior, posterior and likelihood.",
            overallScore: 0.9,
            modelProvider: nil,
            modelID: "claude-opus-5",
            sessionID: "foreverlm://chat/\(sessionID)"
        )
        #expect(second.contains("Appended 2 exchanges"))
        #expect(second.contains("it now holds 3"))
        #expect(second.contains("1 more source linked"))

        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM review_sessions") == 1)
        #expect(try scalarInt(dbPath: dbPath, "SELECT exchange_count FROM review_sessions WHERE id = '\(sessionID)'") == 3)
        #expect(try scalarString(dbPath: dbPath, "SELECT topic FROM review_sessions WHERE id = '\(sessionID)'") == "Bayes in chunks")
        #expect(try scalarString(dbPath: dbPath, "SELECT summary FROM review_sessions WHERE id = '\(sessionID)'") == "Covered prior, posterior and likelihood.")
        #expect(try scalarString(dbPath: dbPath, "SELECT model_provider FROM review_sessions WHERE id = '\(sessionID)'") == "Claude")
        #expect(try scalarString(dbPath: dbPath, "SELECT model_id FROM review_sessions WHERE id = '\(sessionID)'") == "claude-opus-5")
        #expect(try scalarString(dbPath: dbPath, "SELECT status FROM review_sessions WHERE id = '\(sessionID)'") == "completed")
        #expect(try scalarInt(dbPath: dbPath, "SELECT CAST(overall_score * 100 AS INTEGER) FROM review_sessions WHERE id = '\(sessionID)'") == 90)
        #expect(try scalarString(dbPath: dbPath, "SELECT group_concat(sequence_number) FROM (SELECT sequence_number FROM review_exchanges WHERE session_id = '\(sessionID)' ORDER BY sequence_number)") == "1,2,3")
        #expect(try scalarString(dbPath: dbPath, "SELECT question FROM review_exchanges WHERE session_id = '\(sessionID)' AND sequence_number = 3") == "Good. Likelihood?")
        let sourceIDsJSON = try scalarString(dbPath: dbPath, "SELECT source_ids FROM review_sessions WHERE id = '\(sessionID)'") ?? ""
        #expect(sourceIDsJSON.contains("chunk-source-a") && sourceIDsJSON.contains("chunk-source-b"))

        // The same chunk sent again is a retried call: acknowledged, stored once.
        let retried = try store.importReviewChat(
            title: "",
            transcript: "Assistant: And a posterior?\nYou: Belief after evidence.\nAssistant: Good. Likelihood?\nYou: How well the data fit a hypothesis.",
            sourceIDs: nil,
            summary: nil,
            overallScore: nil,
            modelProvider: nil,
            modelID: nil,
            sessionID: sessionID
        )
        #expect(retried.contains("already the end"))
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM review_exchanges WHERE session_id = '\(sessionID)'") == 3)

        // A transcript search finds text that arrived only in the second chunk.
        #expect(try store.searchReviewSessions(queryText: "Likelihood", limit: 5).contains(sessionID))

        // An unknown session is refused rather than silently made.
        #expect(throws: MCPError.self) {
            try store.importReviewChat(
                title: "", transcript: "Assistant: Hi\nYou: Hello", sourceIDs: nil, summary: nil,
                overallScore: nil, modelProvider: nil, modelID: nil, sessionID: "no-such-session"
            )
        }
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM review_sessions") == 1)
    }

    /// A Claude Code session file as the client writes it: the learner's
    /// prompt, a progress line and a tool call, the tool's result (a user
    /// record that is not the learner), a message the learner sent while the
    /// turn ran, a sub-agent line, harness-authored user records, and the
    /// answer with a source link, plus the title the learner gave the session.
    private static func claudeCodeSessionFixture(sessionID: String, answer: String) -> String {
        let lines: [String] = [
            #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-09-20T21:13:35.626Z","sessionId":"\#(sessionID)","content":"ignored"}"#,
            #"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"what does the paper predict from morphology?\n\n<system-reminder>\nContents of CLAUDE.md\n</system-reminder>"},"uuid":"u1","timestamp":"2026-09-20T21:13:35.731Z","sessionId":"\#(sessionID)"}"#,
            #"{"type":"custom-title","customTitle":"Predicting membrane potential from morphology","sessionId":"\#(sessionID)"}"#,
            #"{"parentUuid":"u1","isSidechain":false,"type":"assistant","message":{"model":"claude-fable-5-1","id":"m1","role":"assistant","content":[{"type":"thinking","thinking":"private"},{"type":"text","text":"I'll read the paper first."}]},"uuid":"a1","timestamp":"2026-09-20T21:13:50.000Z"}"#,
            #"{"parentUuid":"a1","isSidechain":false,"type":"assistant","message":{"model":"claude-fable-5-1","id":"m1","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"mcp__foreverlm__get_source_content","input":{"source_id":"src_paper"}}]},"uuid":"a2","timestamp":"2026-09-20T21:13:51.000Z"}"#,
            #"{"parentUuid":"a2","isSidechain":false,"type":"user","message":{"role":"user","content":[{"tool_use_id":"t1","type":"tool_result","content":"Paper text the learner never typed"}]},"uuid":"u2","timestamp":"2026-09-20T21:13:52.000Z","toolUseResult":"x"}"#,
            #"{"parentUuid":"u2","isSidechain":false,"type":"attachment","attachment":{"type":"queued_command","prompt":"and per cell or per well?","timestamp":"2026-09-20T21:14:10.000Z"},"uuid":"q1","timestamp":"2026-09-20T21:14:10.000Z"}"#,
            #"{"parentUuid":"u2","isSidechain":true,"type":"assistant","message":{"model":"claude-fable-5-1","id":"m9","role":"assistant","content":[{"type":"text","text":"sub-agent chatter"}]},"uuid":"s1","timestamp":"2026-09-20T21:14:11.000Z"}"#,
            #"{"parentUuid":"q1","isSidechain":false,"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"},"uuid":"u3","timestamp":"2026-09-20T21:14:12.000Z"}"#,
            #"{"parentUuid":"u3","isSidechain":false,"type":"user","isMeta":true,"message":{"role":"user","content":"Caveat: the messages below were generated by the user while running local commands."},"uuid":"u4","timestamp":"2026-09-20T21:14:13.000Z"}"#,
            #"{"parentUuid":"u4","isSidechain":false,"type":"assistant","message":{"model":"claude-opus-5","id":"m2","role":"assistant","content":[{"type":"text","text":\#(answer)}]},"uuid":"a3","timestamp":"2026-09-20T21:18:40.000Z"}"#,
            #"{"parentUuid":"a3","isSidechain":false,"type":"system","subtype":"stop_hook_summary","uuid":"h1","timestamp":"2026-09-20T21:18:53.925Z"}"#,
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    private static let fixtureAnswer = #""Per cell. [MitoSpace](foreverlm://source/src_paper) predicts TMRM from MitoTracker morphology at R² 0.91.\n\n| Input | R² |\n|---|---|\n| Masks | 0.74 |""#

    @Test("A Claude Code session file is read as the chat the learner saw: their prompts, including one sent mid-turn, and every text the assistant showed, timed and titled; tool calls, results, thinking, sub-agents and harness records are not")
    func claudeCodeSessionFileReadsAsTheChat() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("claude-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { cleanup(dir.path) }
        let sessionID = UUID().uuidString.lowercased()
        let url = dir.appendingPathComponent("\(sessionID).jsonl")
        try Self.claudeCodeSessionFixture(sessionID: sessionID, answer: Self.fixtureAnswer).write(to: url, atomically: true, encoding: .utf8)

        let record = try AssistantTranscriptFile.read(at: url)
        #expect(record.kind == .claudeCodeSession)
        #expect(record.title == "Predicting membrane potential from morphology")
        #expect(record.modelID == "claude-opus-5")
        #expect(record.messages.map(\.role) == [.learner, .assistant, .learner, .assistant])
        #expect(record.messages[0].text == "what does the paper predict from morphology?")
        #expect(record.messages[1].text == "I'll read the paper first.")
        #expect(record.messages[2].text == "and per cell or per well?")
        #expect(record.messages[3].text.hasPrefix("Per cell. [MitoSpace](foreverlm://source/src_paper)"))
        #expect(record.messages[3].text.contains("| Masks | 0.74 |"))
        #expect(record.startedAt == MCPDataStore.parseISODate("2026-09-20T21:13:35.731Z"))
        #expect(record.endedAt == MCPDataStore.parseISODate("2026-09-20T21:18:40.000Z"))
        let joined = record.messages.map(\.text).joined()
        #expect(!joined.contains("Paper text the learner never typed"))
        #expect(!joined.contains("sub-agent chatter"))
        #expect(!joined.contains("private"))
        #expect(!joined.contains("system-reminder"))
        #expect(!joined.contains("/clear"))
        #expect(!joined.contains("Caveat"))

        // Folded into exchanges the way a typed transcript is, each dated by
        // its last message.
        let turns = record.turns
        #expect(turns.count == 3)
        #expect(turns[0].answer == "what does the paper predict from morphology?")
        #expect(turns[0].question == nil)
        #expect(turns[1].question == "I'll read the paper first.")
        #expect(turns[1].answer == "and per cell or per well?")
        #expect(turns[1].answeredAt == MCPDataStore.parseISODate("2026-09-20T21:14:10.000Z"))
        // The answer written after the mid-turn message is its own exchange.
        #expect(turns[2].question?.hasPrefix("Per cell. [MitoSpace]") == true)
        #expect(turns[2].answer == nil)
        #expect(turns[2].answeredAt == MCPDataStore.parseISODate("2026-09-20T21:18:40.000Z"))

        // A file that is not a session is read as a role-labelled transcript.
        let text = dir.appendingPathComponent("export.md")
        try "**User**\nWhat is a prior?\n\n**Claude**\nBelief before evidence.\n".write(to: text, atomically: true, encoding: .utf8)
        let export = try AssistantTranscriptFile.read(at: text)
        #expect(export.kind == .roleLabelledText)
        #expect(export.messages.map(\.text) == ["What is a prior?", "Belief before evidence."])

        // A session id resolves to its file under the notebooks directory.
        #expect(AssistantTranscriptFile.claudeCodeSessionFile(id: sessionID, notebooksRoot: dir.deletingLastPathComponent())?.resolvingSymlinksInPath() == url.resolvingSymlinksInPath())
        #expect(AssistantTranscriptFile.claudeCodeSessionFile(id: UUID().uuidString, notebooksRoot: dir.deletingLastPathComponent()) == nil)
    }

    @Test("import_review_chat with transcript_file stores the chat from Claude Code's own record, verbatim and at its hours, and a later call with session_id brings the stored chat level with the file")
    func importReviewChatReadsTheClaudeCodeSessionFile() throws {
        // The product owner (2026-09-20), on a chat saved as a paraphrase the assistant
        // wrote before answering: "it only saved a summary to foreverlm; not
        // the whole chat. it should do the whole chat … it can probably just do
        // that based on the json file on disk right?"
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(dbPath: dbPath, id: "src_paper", title: "MitoSpace", content: "Lattice light-sheet volumes.")

        let notebooks = URL(fileURLWithPath: tmpPath).appendingPathComponent("notebooks/-Users-me-Developer-mito", isDirectory: true)
        try FileManager.default.createDirectory(at: notebooks, withIntermediateDirectories: true)
        store.claudeCodeProjectsRoot = notebooks.deletingLastPathComponent()
        let sessionID = UUID().uuidString.lowercased()
        let file = notebooks.appendingPathComponent("\(sessionID).jsonl")
        try Self.claudeCodeSessionFixture(sessionID: sessionID, answer: Self.fixtureAnswer).write(to: file, atomically: true, encoding: .utf8)

        // The session id alone names the file; no transcript is typed.
        let first = try store.importReviewChat(
            title: "Cross-modality prediction",
            transcript: "",
            transcriptFile: sessionID,
            sourceIDs: ["src_paper"],
            summary: nil,
            overallScore: nil,
            modelProvider: nil,
            modelID: nil
        )
        #expect(first.contains("from its Claude Code session file"))
        #expect(first.contains("with 3 exchanges"))
        #expect(first.contains("on the day's log for 2026-09-20"))
        #expect(first.contains("the same transcript_file"))
        let reviewID = mcpAnswerValue("session_id", in: first) ?? ""  // the new chat's own `session_id:` line
        #expect(!reviewID.isEmpty)

        let storedAnswer = try scalarString(dbPath: dbPath, "SELECT question FROM review_exchanges WHERE session_id = '\(reviewID)' AND sequence_number = 3") ?? ""
        #expect(storedAnswer.hasPrefix("Per cell. [MitoSpace](foreverlm://source/src_paper)"), "the answer is stored as written, source link and table included")
        #expect(storedAnswer.contains("| Masks | 0.74 |"))
        #expect(try scalarString(dbPath: dbPath, "SELECT user_answer FROM review_exchanges WHERE session_id = '\(reviewID)' AND sequence_number = 1") == "what does the paper predict from morphology?")
        #expect(try scalarString(dbPath: dbPath, "SELECT question FROM review_exchanges WHERE session_id = '\(reviewID)' AND sequence_number = 2") == "I'll read the paper first.")
        #expect(try scalarString(dbPath: dbPath, "SELECT user_answer FROM review_exchanges WHERE session_id = '\(reviewID)' AND sequence_number = 2") == "and per cell or per well?")
        #expect(try scalarString(dbPath: dbPath, "SELECT model_provider FROM review_sessions WHERE id = '\(reviewID)'") == "Claude")
        #expect(try scalarString(dbPath: dbPath, "SELECT model_id FROM review_sessions WHERE id = '\(reviewID)'") == "claude-opus-5")
        let startedAt = try scalarInt(dbPath: dbPath, "SELECT CAST(started_at AS INTEGER) FROM review_sessions WHERE id = '\(reviewID)'")
        let endedAt = try scalarInt(dbPath: dbPath, "SELECT CAST(ended_at AS INTEGER) FROM review_sessions WHERE id = '\(reviewID)'")
        #expect(startedAt == Int(MCPDataStore.parseISODate("2026-09-20T21:13:35.731Z")!.timeIntervalSinceReferenceDate))
        #expect(endedAt == Int(MCPDataStore.parseISODate("2026-09-20T21:18:40.000Z")!.timeIntervalSinceReferenceDate))
        #expect(try scalarInt(dbPath: dbPath, "SELECT CAST(answered_at AS INTEGER) FROM review_exchanges WHERE session_id = '\(reviewID)' AND sequence_number = 3") == endedAt)

        // The same file again: nothing to add.
        let again = try store.importReviewChat(
            title: "", transcript: "", transcriptFile: file.path, sourceIDs: nil, summary: nil,
            overallScore: nil, modelProvider: nil, modelID: nil, sessionID: "foreverlm://chat/\(reviewID)"
        )
        #expect(again.contains("already matches its Claude Code session file"))
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM review_exchanges WHERE session_id = '\(reviewID)'") == 3)

        // The conversation goes on; the file grows; the stored chat follows.
        let more = #"{"parentUuid":"a3","isSidechain":false,"type":"user","message":{"role":"user","content":"is that per cell too?"},"uuid":"u5","timestamp":"2026-09-20T21:20:00.000Z"}"# + "\n"
            + #"{"parentUuid":"u5","isSidechain":false,"type":"assistant","message":{"model":"claude-opus-5","id":"m3","role":"assistant","content":[{"type":"text","text":"Yes: TMRM is a per-cell regression target."}]},"uuid":"a4","timestamp":"2026-09-20T21:20:30.000Z"}"# + "\n"
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(more.utf8))
        try handle.close()
        let grown = try store.importReviewChat(
            title: "", transcript: "", transcriptFile: sessionID, sourceIDs: nil, summary: nil,
            overallScore: nil, modelProvider: nil, modelID: nil, sessionID: reviewID
        )
        #expect(grown.contains("1 exchange appended"))
        #expect(grown.contains("it holds 4 exchanges"))
        // The learner's new question closes the answer's exchange; the reply opens the next.
        #expect(try scalarString(dbPath: dbPath, "SELECT user_answer FROM review_exchanges WHERE session_id = '\(reviewID)' AND sequence_number = 3") == "is that per cell too?")
        #expect(try scalarString(dbPath: dbPath, "SELECT question FROM review_exchanges WHERE session_id = '\(reviewID)' AND sequence_number = 4") == "Yes: TMRM is a per-cell regression target.")
        #expect(try scalarInt(dbPath: dbPath, "SELECT CAST(ended_at AS INTEGER) FROM review_sessions WHERE id = '\(reviewID)'") == Int(MCPDataStore.parseISODate("2026-09-20T21:20:30.000Z")!.timeIntervalSinceReferenceDate))

        // The reported case: a chat first saved as the assistant's retelling,
        // written before the answer. Reconciling with the file replaces the
        // retelling with the answer as it was shown.
        let retold = try store.importReviewChat(
            title: "Retold chat",
            transcript: "**User**\n\nwhat does the paper predict from morphology?\n\n**Claude**\n\nShort answer: membrane potential from morphology at R2 0.91.",
            sourceIDs: ["src_paper"], summary: nil, overallScore: nil, modelProvider: "Claude", modelID: nil
        )
        let retoldID = mcpAnswerValue("session_id", in: retold) ?? ""  // the new chat's own `session_id:` line
        let repaired = try store.importReviewChat(
            title: "", transcript: "", transcriptFile: sessionID, sourceIDs: nil, summary: nil,
            overallScore: nil, modelProvider: nil, modelID: nil, sessionID: retoldID
        )
        // The learner's question matched the record and kept its row; the
        // retelling did not and was replaced by the record's three later turns.
        #expect(repaired.contains("1 stored exchange rewritten from the record"))
        #expect(repaired.contains("2 exchanges appended"))
        #expect(repaired.contains("it holds 4 exchanges"))
        #expect(try scalarString(dbPath: dbPath, "SELECT topic FROM review_sessions WHERE id = '\(retoldID)'") == "Retold chat")
        #expect(try scalarString(dbPath: dbPath, "SELECT question FROM review_exchanges WHERE session_id = '\(retoldID)' AND sequence_number = 3")?.contains("[MitoSpace](foreverlm://source/src_paper)") == true)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM review_exchanges WHERE session_id = '\(retoldID)' AND question LIKE 'Short answer%'") == 0)
        #expect(try scalarString(dbPath: dbPath, "SELECT group_concat(sequence_number) FROM (SELECT sequence_number FROM review_exchanges WHERE session_id = '\(retoldID)' ORDER BY sequence_number)") == "1,2,3,4")

        // A session this Mac has no record of, and a file outside the roots a
        // client may read, are refused by name rather than read elsewhere.
        #expect(throws: MCPError.self) {
            try store.importReviewChat(
                title: "Missing", transcript: "", transcriptFile: UUID().uuidString, sourceIDs: nil,
                summary: nil, overallScore: nil, modelProvider: nil, modelID: nil
            )
        }
        #expect(throws: MCPError.self) {
            try store.importReviewChat(
                title: "Hosts", transcript: "", transcriptFile: "/etc/hosts", sourceIDs: nil,
                summary: nil, overallScore: nil, modelProvider: nil, modelID: nil
            )
        }
        #expect(throws: MCPError.self) {
            try store.importReviewChat(
                title: "Nothing", transcript: "", transcriptFile: nil, sourceIDs: nil,
                summary: nil, overallScore: nil, modelProvider: nil, modelID: nil
            )
        }
    }

    /// A Claude Code session file of plain turns, each stamped at a local
    /// moment on 2026-09-28.
    private static func claudeCodeSession(sessionID: String, turns: [(learner: Bool, text: String, hour: Int, minute: Int, second: Int)]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines: [String] = []
        for (index, turn) in turns.enumerated() {
            let at = Calendar.current.date(from: DateComponents(
                year: 2026, month: 9, day: 28, hour: turn.hour, minute: turn.minute, second: turn.second
            )) ?? Date()
            let stamp = formatter.string(from: at)
            let text = String(data: (try? JSONEncoder().encode(turn.text)) ?? Data(), encoding: .utf8) ?? "\"\""
            if turn.learner {
                lines.append(#"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":\#(text)},"uuid":"u\#(index)","timestamp":"\#(stamp)","sessionId":"\#(sessionID)"}"#)
            } else {
                lines.append(#"{"parentUuid":"u\#(index - 1)","isSidechain":false,"type":"assistant","message":{"model":"claude-opus-5","id":"m\#(index)","role":"assistant","content":[{"type":"text","text":\#(text)}]},"uuid":"a\#(index)","timestamp":"\#(stamp)"}"#)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    @Test("A chat brought level with its Claude Code session file is on the day's log in sittings, and one saved with mark_reviewed false leaves the sources a later call links unreviewed")
    func importReviewChatRecordKeepsItsSittingsAndItsChoice() throws {
        // The reported chat (2026-09-28): imported with mark_reviewed false in
        // the afternoon, then brought level with its session file at seven
        // with more source_ids. It was drawn 14:26–19:04, 278 minutes, and
        // every added source came back reviewed, done and read.
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(dbPath: dbPath, id: "src_first", title: "First", content: "First paper.")
        try insertSource(dbPath: dbPath, id: "src_later_paper", title: "Later", content: "Later paper.")
        try insertSource(dbPath: dbPath, id: "src_later_episode", title: "Episode", content: "An episode.", sourceType: "podcast")

        let notebooks = URL(fileURLWithPath: tmpPath).appendingPathComponent("notebooks/-Users-me-Developer-mito", isDirectory: true)
        try FileManager.default.createDirectory(at: notebooks, withIntermediateDirectories: true)
        store.claudeCodeProjectsRoot = notebooks.deletingLastPathComponent()
        let sessionID = UUID().uuidString.lowercased()
        let file = notebooks.appendingPathComponent("\(sessionID).jsonl")
        let afternoon: [(learner: Bool, text: String, hour: Int, minute: Int, second: Int)] = [
            (true, "what did these papers find?", 14, 26, 10),
            (false, "Mostly that the effect holds in vivo.", 14, 29, 40),
        ]
        try Self.claudeCodeSession(sessionID: sessionID, turns: afternoon).write(to: file, atomically: true, encoding: .utf8)

        let first = try store.importReviewChat(
            title: "What the papers found", transcript: "", transcriptFile: sessionID,
            sourceIDs: ["src_first"], summary: nil, overallScore: nil, modelProvider: nil, modelID: nil,
            marksReviewed: false
        )
        #expect(first.contains("as a saved chat"))
        #expect(first.contains("on the day's log for 2026-09-28 (14:26–14:30) at the hours it ran"))
        let reviewID = mcpAnswerValue("session_id", in: first) ?? ""  // the new chat's own `session_id:` line
        #expect(!reviewID.isEmpty)

        // The learner comes back at seven; the file grows, and the call that
        // brings the chat level links more sources without saying mark_reviewed.
        let evening = afternoon + [
            (true, "and the two newer ones?", 19, 0, 5),
            (false, "They agree, with one caveat.", 19, 4, 20),
        ]
        try Self.claudeCodeSession(sessionID: sessionID, turns: evening).write(to: file, atomically: true, encoding: .utf8)
        let later = try store.importReviewChat(
            title: "", transcript: "", transcriptFile: sessionID,
            sourceIDs: ["src_later_paper", "src_later_episode"], summary: nil, overallScore: nil,
            modelProvider: nil, modelID: nil, sessionID: reviewID
        )
        #expect(later.contains("2 more sources linked, without marking them reviewed"))
        #expect(later.contains("on the day's log for 2026-09-28 (14:26–14:30, 19:00–19:05) at the hours it ran"))

        let ids = "('src_first', 'src_later_paper', 'src_later_episode')"
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM scheduled_sources WHERE source_id IN \(ids)") == 0)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM source_activity_days WHERE source_id IN \(ids)") == 0)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM source_projection WHERE id IN \(ids) AND read_at IS NOT NULL") == 0)
        #expect(try scalarString(dbPath: dbPath, "SELECT kind FROM review_sessions WHERE id = '\(reviewID)'") == "chat")
        let sourceIDsJSON = try scalarString(dbPath: dbPath, "SELECT source_ids FROM review_sessions WHERE id = '\(reviewID)'") ?? ""
        #expect(sourceIDsJSON.contains("src_later_paper") && sourceIDsJSON.contains("src_later_episode"), "linked all the same")

        let log = try #require(try store.knowledgeStore().loadDayPlan("2026-09-28")).activities.filter { $0.targetID == reviewID }
        #expect(log.map(\.durationMinutes).sorted() == [4, 5], "two sittings, not 278 minutes")
    }

    @Test("forget_source_activity takes back a review recorded in error: the automatic entry, its activity day and the read stamp go on every device, a podcast's included")
    func forgetSourceActivityTakesBackAWrongReview() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(dbPath: dbPath, id: "src_paper", title: "A paper", content: "A paper.")
        try insertSource(dbPath: dbPath, id: "src_episode", title: "An episode", content: "An episode.", sourceType: "podcast")
        let knowledge = try store.knowledgeStore()

        // What the append path wrote for each of the seven sources on 2026-09-28.
        try store.markScheduledSourcesReviewed(["src_paper", "src_episode"])
        #expect(try knowledge.scheduledSourceID(forSource: "src_paper") != nil)
        let ids = "('src_paper', 'src_episode')"
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM source_projection WHERE id IN \(ids) AND read_at IS NOT NULL") == 2)
        // The tools that existed could not take it back.
        #expect(throws: MCPError.self) { try store.unscheduleSources(sourceIDs: ["src_paper"]) }

        let today = DayPlan.dateString(for: Date())
        let registry = MCPToolRegistry(store: store)
        let outcome = await registry.callToolDetailed(
            name: "forget_source_activity",
            arguments: ["source_ids": ["src_paper", "src_episode"], "date": today]
        )
        #expect(!outcome.isError)
        let result = try parseJSON(outcome.text)
        #expect(result["status"] as? String == "forgotten")
        #expect(result["date"] as? String == today)
        let sources = try #require(result["sources"] as? [[String: Any]])
        #expect(sources.map { $0["source_id"] as? String } == ["src_paper", "src_episode"])
        #expect(sources.allSatisfy { $0["read_at_cleared"] is String && $0["was_completed"] as? Bool == true })
        let day = try #require((sources.first?["days"] as? [[String: Any]])?.first)
        #expect(day["date"] as? String == today)
        #expect(day["completed_kinds"] as? [String] == ["review"])

        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM scheduled_sources WHERE source_id IN \(ids)") == 0)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM source_activity_days WHERE source_id IN \(ids)") == 0)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM source_projection WHERE id IN \(ids) AND read_at IS NOT NULL") == 0)
        // And the sources are still in the library.
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM sources WHERE id IN \(ids)") == 2)
    }

    @Test("forget_source_activity changes nothing when any source has a plan, activity on another day, or nothing recorded")
    func forgetSourceActivityRefusesWhatItWouldWronglyErase() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        for id in ["src_planned", "src_history", "src_wrong", "src_untouched"] {
            try insertSource(dbPath: dbPath, id: id, title: id, content: "Text of \(id).")
        }
        let knowledge = try store.knowledgeStore()
        let now = Date()
        let today = DayPlan.dateString(for: now)
        let yesterday = try #require(Calendar.current.date(byAdding: .day, value: -1, to: now))

        // A plan the learner made and then reviewed.
        _ = try await store.assignSourcesToDay(sourceIDs: ["src_planned"], dateString: today)
        try store.markScheduledSourcesReviewed(["src_planned"])
        // Real reading yesterday, and a wrong review today, on one automatic entry.
        try knowledge.recordScheduledSourceActivity(sourceID: "src_history", on: yesterday, kind: .reading)
        try store.markScheduledSourcesReviewed(["src_history", "src_wrong"])

        /// The refusal's text, or "" when the call went through.
        func refusal(_ ids: [String], on date: String) -> String {
            do {
                _ = try store.forgetSourceActivity(sourceIDs: ids, dateString: date)
                return ""
            } catch {
                return error.localizedDescription
            }
        }
        #expect(refusal(["src_wrong", "src_planned"], on: today).contains("unschedule_sources"))
        #expect(refusal(["src_wrong", "src_history"], on: today).contains("also has activity on \(DayPlan.dateString(for: yesterday))"))
        #expect(refusal(["src_wrong", "src_untouched"], on: today).contains("src_untouched has no recorded activity"))
        // All or nothing: the source that could have been forgotten was not.
        #expect(try knowledge.scheduledSourceID(forSource: "src_wrong") != nil)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM source_projection WHERE id = 'src_wrong' AND read_at IS NOT NULL") == 1)
        // The day is required, never assumed, and has to be the day it was recorded.
        #expect(throws: MCPError.self) { try store.forgetSourceActivity(sourceIDs: ["src_wrong"], dateString: nil) }
        #expect(refusal(["src_wrong"], on: DayPlan.dateString(for: yesterday)).contains("also has activity on \(today)"))
        // Alone, on its day, it goes.
        #expect(refusal(["src_wrong"], on: today).isEmpty)
        #expect(try knowledge.scheduledSourceID(forSource: "src_wrong") == nil)
        // The plan and the history are as they were.
        #expect(try knowledge.scheduledSourceID(forSource: "src_planned") != nil)
        #expect(try knowledge.loadSourceActivityDays(sourceID: "src_history").count == 2)
    }

    @Test("import_review_chat files a first import directly under an explicit Notebook")
    func importReviewChatFilesUnderNotebook() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(
            dbPath: dbPath,
            id: "notebook-import-source",
            title: "Notebook import source",
            content: "A completed external chat can be filed in its Notebook at import time."
        )

        let knowledge = try store.knowledgeStore()
        let notebook = try knowledge.createCompanionGoal(
            title: "Mito Phenotyping",
            topic: "mitochondrial phenotyping",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: []
        )

        let imported = try store.importReviewChat(
            title: "Energy transformation assays",
            transcript: "Assistant: What did the assays show?\nYou: Energetically costly compensation.",
            sourceIDs: ["notebook-import-source"],
            summary: "Primary mitochondrial disease phenotyping.",
            overallScore: nil,
            modelProvider: "ChatGPT",
            modelID: nil,
            notebookID: notebook.id
        )
        let sessionID = mcpAnswerValue("session_id", in: imported) ?? ""  // the new chat's own `session_id:` line
        #expect(!sessionID.isEmpty)
        #expect(imported.contains("Filed under Notebook ‘Mito Phenotyping’."))
        #expect(!imported.contains("(id: "), "no id beside a name (Prompts.hiddenIDs)")
        #expect(try scalarString(
            dbPath: dbPath,
            "SELECT goal_id FROM review_sessions WHERE id = '\(sessionID)'"
        ) == notebook.id)
        #expect(try knowledge.loadReviewSessionForSync(sessionID)?.goalID == notebook.id)

        // Notebook placement is independent of the Notebook's approved source
        // pool, matching Move to Notebook in the sidebar. The external chat can
        // retain exact library citations without silently adding those sources
        // to the Notebook.
        #expect(try knowledge.loadLearningGoal(notebook.id)?.approvedSourceIDs.isEmpty == true)
        #expect(try store.reviewSessionSourceIDs(sessionID: sessionID) == ["notebook-import-source"])

        // Later chunks keep the first import's Notebook. Repeating notebook_id is
        // harmless and is not a request to move an existing imported chat.
        _ = try store.importReviewChat(
            title: "Ignored",
            transcript: "Assistant: Which context matters?\nYou: The standardized whole-room chamber.",
            sourceIDs: nil,
            summary: nil,
            overallScore: nil,
            modelProvider: nil,
            modelID: nil,
            notebookID: "not-a-notebook",
            sessionID: sessionID
        )
        #expect(try scalarString(
            dbPath: dbPath,
            "SELECT goal_id FROM review_sessions WHERE id = '\(sessionID)'"
        ) == notebook.id)

        #expect(throws: MCPError.self) {
            try store.importReviewChat(
                title: "Invalid Notebook",
                transcript: "Assistant: Hi\nYou: Hello",
                sourceIDs: [],
                summary: nil,
                overallScore: nil,
                modelProvider: nil,
                modelID: nil,
                notebookID: "not-a-notebook"
            )
        }
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM review_sessions") == 1)
    }

    @Test("Review sessions link to a Notebook only when notebook id is explicit")
    func reviewSessionsRequireExplicitNotebookAttribution() async throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(
            dbPath: dbPath,
            id: "source-a",
            title: "Explicit notebook review",
            content: "Review content."
        )

        let store = MCPDataStore(dbPath: dbPath)
        let knowledge = try store.knowledgeStore()
        let notebook = try knowledge.createCompanionGoal(
            title: "Review Notebook",
            topic: "review",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: ["source-a"]
        )
        let priorSelection = ActiveNotebookPreference.notebookID
        ActiveNotebookPreference.notebookID = notebook.id
        defer { ActiveNotebookPreference.notebookID = priorSelection }

        func sessionID(from response: String) -> String {
            response
                .components(separatedBy: "\n")
                .first { $0.hasPrefix("Session ID: ") }?
                .replacingOccurrences(of: "Session ID: ", with: "") ?? ""
        }

        let unscoped = try await store.startReviewSession(
            topic: "Explicit notebook review",
            sourceID: "source-a"
        )
        let unscopedID = sessionID(from: unscoped)
        #expect(!unscopedID.isEmpty)
        #expect(try scalarString(
            dbPath: dbPath,
            "SELECT goal_id FROM review_sessions WHERE id = '\(unscopedID)'"
        ) == nil)

        let scoped = try await store.startScopedReviewSession(
            topic: "Explicit notebook review",
            sourceID: "source-a",
            notebookID: notebook.id
        )
        let scopedID = sessionID(from: scoped)
        #expect(try scalarString(
            dbPath: dbPath,
            "SELECT goal_id FROM review_sessions WHERE id = '\(scopedID)'"
        ) == notebook.id)
        #expect(scoped.contains("linked to your Notebook \"Review Notebook\""))
    }

    @Test("startReviewSession binds to the host chat session instead of creating a phantom one")
    func startReviewSessionBindsToHostSession() async throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        try insertSource(
            dbPath: dbPath,
            id: "source-a",
            title: "AI for Bio fuzzy API problem drug discovery",
            content: "Drug discovery source content."
        )

        let store = MCPDataStore(dbPath: dbPath)
        // Stand in for the session in-app Chat opens before the model calls any tool.
        let hostID = UUID().uuidString
        try store.knowledgeStore().createReviewSession(id: hostID, topic: "Chat", sourceIDs: [], startedAt: Date(), goalID: nil)

        let started = try await store.startReviewSession(
            topic: "Please quiz me on AI for Bio fuzzy API problem drug discovery",
            hostSessionID: hostID
        )

        // No second session row: the review is the chat the learner is already in,
        // and the reviewed source is linked onto it.
        #expect(started.contains("Session ID: \(hostID)"))
        #expect(started.contains("This chat is the review session"))
        #expect(try store.reviewSessionSourceIDs(sessionID: hostID) == ["source-a"])
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM review_sessions") == 1)
    }

    @Test("startReviewSession bound to a host chat ignores a caller idempotency key")
    func startReviewSessionIgnoresOperationIDForHostSession() async throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        try insertSource(
            dbPath: dbPath,
            id: "source-a",
            title: "Metabolism",
            content: "Glycolysis yields ATP without oxygen."
        )

        let store = MCPDataStore(dbPath: dbPath)
        let hostID = UUID().uuidString
        try store.knowledgeStore().createReviewSession(id: hostID, topic: "Chat", sourceIDs: [], startedAt: Date(), goalID: nil)

        // The model was offered no such key, but a chat that passes one anyway is
        // still the review; the host session is the only identity that matters.
        for operationID in ["review-request-1", "", "   "] {
            let started = try await store.startReviewSession(
                topic: "Metabolism book review",
                sourceIDs: ["source-a"],
                operationID: operationID,
                hostSessionID: hostID
            )
            #expect(started.contains("Session ID: \(hostID)"))
        }
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM review_sessions") == 1)
    }

    @Test("a blank operation_id from a remote caller means no idempotency key")
    func blankOperationIDMeansNone() async throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(dbPath: dbPath, id: "source-a", title: "Metabolism", content: "Glycolysis yields ATP.")
        let store = MCPDataStore(dbPath: dbPath)

        _ = try await store.startReviewSession(topic: "Metabolism", sourceIDs: ["source-a"], operationID: "")
        _ = try await store.startReviewSession(topic: "Metabolism", sourceIDs: ["source-a"], operationID: "  ")

        // Two plain starts, two sessions: neither blank key was treated as a retry.
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM review_sessions") == 2)
    }

    @Test("endReviewSession with a host chat ends that chat and does not duplicate its transcript")
    func endReviewSessionUsesHostSession() throws {
        let (_, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        let store = MCPDataStore(dbPath: dbPath)
        let hostID = UUID().uuidString
        let knowledge = try store.knowledgeStore()
        try knowledge.createReviewSession(id: hostID, topic: "Chat", sourceIDs: [], startedAt: Date(), goalID: nil)
        _ = try knowledge.addReviewExchange(
            sessionID: hostID,
            question: "",
            answer: "The endpoints are underspecified.",
            evaluation: "Right — say why.",
            score: nil,
            knowledgeNote: nil,
            sourceRefs: []
        )

        // A lost or invented session id must still resolve back to the host chat.
        _ = try store.endReviewSession(
            sessionID: "00000000-DEAD-BEEF-0000-000000000000",
            hostSessionID: hostID,
            overallScore: 0.8,
            summary: "Solid on the fuzzy API issue.",
            transcript: "Claude: What makes the API fuzzy?\nMe: The endpoints are underspecified."
        )

        // One session, one exchange: the chat's own turns, not a re-imported copy.
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM review_sessions") == 1)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM review_exchanges WHERE session_id = '\(hostID)'") == 1)
        #expect(try scalarString(dbPath: dbPath, "SELECT status FROM review_sessions WHERE id = '\(hostID)'") == "completed")
    }

    @Test("end_review_session rejects missing, nonfinite, boolean, and out-of-range scores")
    func endReviewSessionRequiresStrictScore() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let sessionID = "strict-score-session"
        try store.knowledgeStore().createReviewSession(
            id: sessionID,
            topic: "Strict score",
            sourceIDs: [],
            startedAt: Date()
        )
        let registry = MCPToolRegistry(store: store)
        // A numeric string is read as the number the schema declares
        // (`argumentsShaped`, 2026-11-10), so "0.5" is a score. A string that
        // spells no finite number, or one out of range, is still refused.
        let invalidScores: [Any?] = [nil, true, Double.nan, -0.01, 1.01, "half", "nan", "1.5"]

        for invalidScore in invalidScores {
            var arguments: [String: Any] = [
                "session_id": sessionID,
                "summary": "Must not complete.",
            ]
            if let invalidScore { arguments["overall_score"] = invalidScore }
            let outcome = await registry.callToolDetailed(
                name: "end_review_session",
                arguments: arguments,
                access: .internalFullAccess
            )
            #expect(outcome.isError)
            #expect(outcome.text.contains("overall_score"))
        }

        #expect(try scalarString(
            dbPath: dbPath,
            "SELECT status FROM review_sessions WHERE id = '\(sessionID)'"
        ) == "active")
    }

    @Test("replaying whole session completion preserves endedAt, quiz count, gaps, and transcript")
    func endReviewSessionCompletionIsIdempotent() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(
            dbPath: dbPath,
            id: "source-replay",
            title: "Replay-safe review",
            content: "Retrieval practice requires an unaided attempt before feedback."
        )
        let knowledge = try store.knowledgeStore()
        let notebook = try knowledge.createCompanionGoal(
            title: "Replay Notebook",
            topic: "retrieval",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: ["source-replay"]
        )
        let started = try await store.startScopedReviewSession(
            topic: "Replay-safe review",
            sourceID: "source-replay",
            notebookID: notebook.id
        )
        let id = parsedSessionID(from: started)
        let transcript = "Tutor: Why retrieve first?\nLearner: To expose what I can actually access."
        let gaps: [[String: Any]] = [[
            "summary": "Needs to distinguish retrieval strength from familiarity.",
            "source_id": "source-replay",
            "severity": 0.6,
            "status": "open",
        ]]

        _ = try store.endReviewSession(
            sessionID: id,
            overallScore: 0.76,
            summary: "Understands the basic retrieval-before-feedback sequence.",
            transcript: transcript,
            gaps: gaps
        )
        let endedAt = try scalarString(
            dbPath: dbPath,
            "SELECT printf('%.17g', ended_at) FROM review_sessions WHERE id = '\(id)'"
        )
        let quizCount = try scalarInt(
            dbPath: dbPath,
            "SELECT quiz_count FROM learning_goal_items WHERE goal_id = '\(notebook.id)' AND source_id = 'source-replay'"
        )
        let gapCount = try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM learning_goal_gaps WHERE goal_id = '\(notebook.id)'"
        )
        let exchangeCount = try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM review_exchanges WHERE session_id = '\(id)'"
        )

        _ = try store.endReviewSession(
            sessionID: id,
            overallScore: 0.76,
            summary: "Understands the basic retrieval-before-feedback sequence.",
            transcript: transcript,
            gaps: gaps
        )

        #expect(try scalarString(
            dbPath: dbPath,
            "SELECT printf('%.17g', ended_at) FROM review_sessions WHERE id = '\(id)'"
        ) == endedAt)
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT quiz_count FROM learning_goal_items WHERE goal_id = '\(notebook.id)' AND source_id = 'source-replay'"
        ) == quizCount)
        #expect(quizCount == 1)
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM learning_goal_gaps WHERE goal_id = '\(notebook.id)'"
        ) == gapCount)
        #expect(gapCount == 1)
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM review_exchanges WHERE session_id = '\(id)'"
        ) == exchangeCount)
        #expect(exchangeCount == 1)
    }

    @Test("memoryReview returns durable concept IDs, reasons, rubrics, and anchors")
    func memoryReviewReturnsConceptPlan() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let content = "Retrieval practice strengthens later access more than passive rereading."
        try insertSource(
            dbPath: dbPath,
            id: "source-memory",
            title: "Retrieval practice",
            content: content
        )
        let now = Date()
        let item = MemoryItem(
            id: "memory-item",
            kind: .concept,
            target: "Explain why retrieval practice improves later access",
            rubricJSON: #"{"criteria":["Contrasts retrieval with rereading"]}"#,
            sources: [
                MemoryItemSource(
                    id: "memory-anchor",
                    memoryItemID: "memory-item",
                    sourceID: "source-memory",
                    excerpt: content,
                    sourceSHA256: PaperContentPreparationService.sha256(content),
                    sortIndex: 0
                ),
            ],
            createdAt: now.addingTimeInterval(-10 * 86_400),
            updatedAt: now.addingTimeInterval(-10 * 86_400)
        )
        try store.knowledgeStore().saveMemoryItem(item)
        _ = try store.knowledgeStore().recordMemoryAttempt(
            MemoryAttempt(
                id: "memory-struggle-attempt",
                memoryItemID: item.id,
                attemptType: .review,
                prompt: "Why is retrieval different from rereading?",
                learnerAnswer: "Rereading makes it familiar.",
                feedback: "You did not explain the diagnostic effort of retrieval.",
                score: 0.4,
                scheduleRating: .hard,
                gradeState: .graded,
                evidenceJSON: #"{"missing_rubric_elements":["Contrasts retrieval with rereading"],"misconception":"Equates familiarity with recall","retrieval_quality":"hinted"}"#,
                attemptedAt: now.addingTimeInterval(-2 * 86_400)
            )
        )

        let output = try await store.memoryReview(
            goalID: nil,
            limit: 5,
            startSession: false
        )
        let payload = try parseJSON(output)
        let memoryItems = payload["memory_items"] as? [[String: Any]]
        let first = memoryItems?.first

        #expect(first?["item_id"] as? String == "memory-item")
        #expect(first?["reason"] as? String == "struggle")
        #expect(first?["learning_target"] as? String == item.target)
        #expect(first?["grading_rubric_json"] as? String == item.rubricJSON)
        #expect((first?["sources"] as? [[String: Any]])?.first?["source_id"] as? String == "source-memory")
        let prior = (first?["prior_struggles"] as? [[String: Any]])?.first
        #expect(prior?["retrieval_quality"] as? String == "hinted")
        #expect((prior?["missing_rubric_elements"] as? [String]) == ["Contrasts retrieval with rereading"])
        #expect(prior?["misconception"] as? String == "Equates familiarity with recall")
        #expect(first?["ask"] == nil, "a target from before cards is worded afresh")
    }

    @Test("memoryReview hands over a kept card's wording to ask, the learner's rewording when there is one")
    func memoryReviewAsksKeptCardsAsWorded() async throws {
        // The card state rows in a suite of the test's own: on a host whose library syncs generation 2,
        // the standard defaults' rows give way to the Card records (`MemoryCardStateStore.usesCardRecords`),
        // so a rewording written there would never be read.
        let (store, dbPath, defaults, cleanup) = try makeCardStore()
        defer { cleanup() }
        let content = "Retrieval practice strengthens later access more than passive rereading."
        try insertSource(dbPath: dbPath, id: "source-card", title: "Retrieval practice", content: content)
        let now = Date()
        let card = MemoryCard(
            cardID: "card-\(UUID().uuidString)",
            front: "What strengthens later access more than rereading?",
            back: "Retrieval practice.",
            origin: .drafted,
            deckID: MemoryCard.draftDeckID(sourceID: "source-card")
        )
        let knowledge = try store.knowledgeStore()
        let item = try knowledge.keepMemoryCard(
            card, sourceID: "source-card", quote: "Retrieval practice strengthens later access",
            at: now.addingTimeInterval(-10 * 86_400)
        )
        #expect(try knowledge.recordSelfGradedMemoryCardAttempt(
            memoryItemID: item.id, prompt: card.front, remembered: false, sessionKey: "review-1",
            at: now.addingTimeInterval(-2 * 86_400)
        ) == .recorded)

        func askedWording() async throws -> String? {
            let payload = try parseJSON(try await store.memoryReview(goalID: nil, limit: 5, startSession: false))
            let entry = (payload["memory_items"] as? [[String: Any]])?.first { $0["item_id"] as? String == item.id }
            return entry?["ask"] as? String
        }
        #expect(try await askedWording() == card.front)

        // The learner's own rewording lives in the deck's state row, not the item.
        let key = MemoryCardDeckState.preferenceKey(deckID: try #require(card.deckID))
        var row = MemoryCardDeckState()
        row.markKept(cardID: card.cardID, memoryItemID: item.id, at: now)
        row.cards[card.cardID]?.editedFront = "Which beats rereading for later access?"
        defaults.set(row.preferenceValue, forKey: key)
        #expect(try await askedWording() == "Which beats rereading for later access?")
        #expect(MCPDataStore.memoryReviewSessionInstructions.contains("An item with `ask` is a card the learner kept"))
    }
}

#endif
