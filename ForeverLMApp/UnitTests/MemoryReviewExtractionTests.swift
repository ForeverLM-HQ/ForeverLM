import Foundation
import Testing
@testable import ForeverLM

/// The memory review extracts ideas for every cohort source in parallel and
/// then keeps the sources that yielded ideas. Build 45 crashed on the Memory
/// button because the child tasks' results came back keyed to an empty source
/// id: the tuple around `try await` was miscompiled at -O, so no source was
/// ever "prepared", the tutor was told every source was skipped, and the task
/// group was torn down under children that were still finishing. This pins
/// the accounting: a prepared source stays, a source without text is named,
/// and nothing is reported as "not prepared" — the reason that only appears
/// when a result never reached the loop under its own id.
@Suite("Memory review idea extraction")
struct MemoryReviewExtractionTests {

    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-memory-extraction-\(UUID().uuidString)", isDirectory: true)
    }

    private func cohortSource(_ id: String, title: String) -> CohortSource {
        CohortSource(
            sourceID: id,
            title: title,
            sourceType: "article",
            role: .spine,
            consumedAt: Date(),
            lastDiscussedAt: nil,
            reviewCount: 0,
            confidence: .substantial,
            bridgeTo: nil,
            reason: "consumed yesterday"
        )
    }

    /// A source whose stored ideas already match its text: prepared without a
    /// model call, which is what lets this run offline.
    private func seedPreparedSource(_ id: String, title: String, text: String, on storage: StorageService) async throws {
        var article = StudioArticle(url: "https://example.com/\(id)", title: title, sourceType: .article, id: id)
        article.content = text
        article.state = .ready
        try await storage.saveSource(article)
        let hash = PaperContentPreparationService.sha256(text)
        let now = Date()
        let idea = SourceIdea(
            id: SourceIdea.id(sourceID: id, contentHash: hash, index: 0),
            sourceID: id,
            statement: "\(title) says one thing worth remembering.",
            recallNote: "",
            anchors: [],
            wanted: false,
            contentHash: hash,
            sortIndex: 0,
            createdAt: now,
            updatedAt: now
        )
        try await storage.replaceSourceIdeas(sourceID: id, contentHash: hash, ideas: [idea])
    }

    @MainActor
    @Test("Every source's result lands under its own id: prepared sources stay, a textless one is named")
    func resultsStayUnderTheirOwnSource() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        try await seedPreparedSource("src-alpha", title: "Alpha", text: "Alpha is the first letter, and this text is its source.", on: storage)
        try await seedPreparedSource("src-beta", title: "Beta", text: "Beta follows alpha, and this text is its source.", on: storage)
        // No text at all: extraction throws before it would need a model.
        try await storage.saveSource(StudioArticle(url: "https://example.com/src-gamma", title: "Gamma", sourceType: .article, id: "src-gamma"))

        let manager = ReviewSessionManager(storage: storage)
        let cohort = LearningCohort(
            assembledAt: Date(),
            windowDays: 10,
            sources: [
                cohortSource("src-alpha", title: "Alpha"),
                cohortSource("src-gamma", title: "Gamma"),
                cohortSource("src-beta", title: "Beta"),
            ],
            unfinished: [],
            droppedSpine: 0,
            droppedSpacing: 0
        )

        let extraction = await manager.extractIdeas(for: cohort)

        #expect(extraction.cohort.sources.map(\.sourceID) == ["src-alpha", "src-beta"])
        #expect(extraction.skipped.count == 1)
        let skipped = extraction.skipped.first ?? ""
        #expect(skipped.hasPrefix("Gamma — "))
        #expect(skipped.contains("no readable text"))
        // "not prepared" is the fallback for a source whose result never
        // arrived under its own id — the exact symptom of the build 45 crash.
        #expect(!extraction.skipped.contains { $0.contains("not prepared") })
    }

    @MainActor
    @Test("A bridge whose anchor could not be prepared is dropped with it")
    func bridgeFollowsItsAnchor() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        try await seedPreparedSource("src-bridge", title: "Bridge", text: "A bridge source with text and ideas.", on: storage)
        try await storage.saveSource(StudioArticle(url: "https://example.com/src-anchor", title: "Anchor", sourceType: .article, id: "src-anchor"))

        var bridge = cohortSource("src-bridge", title: "Bridge")
        bridge = CohortSource(
            sourceID: bridge.sourceID, title: bridge.title, sourceType: bridge.sourceType, role: .bridge,
            consumedAt: bridge.consumedAt, lastDiscussedAt: nil, reviewCount: 0,
            confidence: .partial, bridgeTo: "src-anchor", reason: "close to Anchor"
        )
        let cohort = LearningCohort(
            assembledAt: Date(), windowDays: 10,
            sources: [cohortSource("src-anchor", title: "Anchor"), bridge],
            unfinished: [], droppedSpine: 0, droppedSpacing: 0
        )

        let extraction = await ReviewSessionManager(storage: storage).extractIdeas(for: cohort)

        // The bridge was prepared, so it is not "skipped"; it leaves the cohort
        // only because the anchor it would be put in friction with did not.
        #expect(extraction.cohort.sources.isEmpty)
        #expect(extraction.skipped.count == 1)
        #expect(extraction.skipped.first?.hasPrefix("Anchor — ") == true)
        #expect(!extraction.skipped.contains { $0.contains("not prepared") })
    }
}
