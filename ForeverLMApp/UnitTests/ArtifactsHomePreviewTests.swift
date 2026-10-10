import Testing
import Foundation
import AppKit
@testable import ForeverLM

@Suite("Artifacts Home Previews")
struct ArtifactsHomePreviewTests {
    @Test("A Site's page is photographed; a Doc draws its own lines")
    func previewRequestsByKind() throws {
        let url = "https://sites.foreverlm.com/krebs-cycle/"
        #expect(
            ArtifactsHomePane.previewRequest(kind: .site, linkedURL: url, linkedKind: .foreverlmSite)
                == .page(url: URL(string: url)!, kind: .foreverlmSite)
        )
        #expect(
            ArtifactsHomePane.previewRequest(kind: .site, linkedURL: "https://claude.ai/public/artifacts/abc", linkedKind: .claudeArtifact)
                == .page(url: URL(string: "https://claude.ai/public/artifacts/abc")!, kind: .claudeArtifact)
        )
        #expect(ArtifactsHomePane.previewRequest(kind: .doc, linkedURL: nil, linkedKind: nil) == nil)
        #expect(ArtifactsHomePane.previewRequest(kind: .doc, linkedURL: "https://docs.google.com/document/d/x/edit", linkedKind: .googleDoc) == nil)
        // A site record with no usable address keeps its glyph.
        #expect(ArtifactsHomePane.previewRequest(kind: .site, linkedURL: "not a url", linkedKind: nil) == nil)
        #expect(ArtifactsHomePane.previewRequest(kind: .site, linkedURL: nil, linkedKind: nil) == nil)
    }

    @Test("The cache key changes with the revision and not otherwise")
    func cacheKeyFollowsRevision() {
        let then = Date(timeIntervalSince1970: 1_700_000_000)
        let same = ArtifactPreviewStore.cacheKey(id: "a1", updatedAt: then)
        #expect(same == ArtifactPreviewStore.cacheKey(id: "a1", updatedAt: then.addingTimeInterval(0.4)))
        #expect(same != ArtifactPreviewStore.cacheKey(id: "a1", updatedAt: then.addingTimeInterval(60)))
        #expect(same != ArtifactPreviewStore.cacheKey(id: "a2", updatedAt: then))
    }

    @Test("A Doc's excerpt is its prose: marks out, its own heading dropped, cut at length")
    func excerptStripsMarkdown() {
        let markdown = """
        # The Landscape of Mitochondrial Therapeutics

        <!-- draft -->
        ![figure](fig.png)

        ## Why now

        Three **companies** raised _rounds_ in 2026, each on a [membrane potential](https://example.com) readout.

        - first point<br />
        1. numbered `code` point
        > a quote

        ```swift
        let hidden = true
        ```

        | a | b |
        ---
        """
        let excerpt = ArtifactPreviewExcerpt.make(markdown: markdown, title: "The Landscape of Mitochondrial Therapeutics")
        #expect(excerpt == "Why now Three companies raised rounds in 2026, each on a membrane potential readout. first point numbered code point a quote")
    }

    @Test("A long body is cut with an ellipsis; an empty one is empty")
    func excerptLength() {
        let long = String(repeating: "word ", count: 200)
        let excerpt = ArtifactPreviewExcerpt.make(markdown: long, title: "T")
        #expect(excerpt.hasSuffix("…"))
        #expect(excerpt.count <= ArtifactPreviewExcerpt.maximumLength + 1)
        #expect(ArtifactPreviewExcerpt.make(markdown: "", title: "T").isEmpty)
        #expect(ArtifactPreviewExcerpt.make(markdown: "# T\n", title: "T").isEmpty)
    }

    @Test("The store makes a picture once per key, keeps it on disk, and remembers a failure")
    @MainActor
    func storeMakesOncePerKey() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-previews-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = ThumbnailDiskCache(cacheDirectory: directory)
        let calls = Calls()
        let store = ArtifactPreviewStore(diskCache: disk) { request in
            await calls.record(request)
            guard case .page(let url, _) = request, url.host == "ok.example" else { return nil }
            return NSImage(size: NSSize(width: 16, height: 10), flipped: false) { rect in
                NSColor.red.setFill()
                rect.fill()
                return true
            }
        }
        let good = ArtifactPreviewStore.Request.page(url: URL(string: "https://ok.example/a")!, kind: .foreverlmSite)
        let bad = ArtifactPreviewStore.Request.page(url: URL(string: "https://down.example/b")!, kind: nil)

        #expect(store.image(for: "k1") == nil)
        store.request(good, for: "k1")
        store.request(good, for: "k1")
        store.request(bad, for: "k2")
        try await waitUntil {
            let attempts = await calls.count
            return store.image(for: "k1") != nil && attempts >= 2
        }

        #expect(store.image(for: "k1")?.size == NSSize(width: 16, height: 10))
        #expect(store.image(for: "k2") == nil)
        var attempts = await calls.count
        #expect(attempts == 2, "one attempt per key, the repeat coalesced")

        // A failed key is not asked for again this session.
        store.request(bad, for: "k2")
        try await Task.sleep(for: .milliseconds(50))
        attempts = await calls.count
        #expect(attempts == 2)

        // The JPEG lands on disk under the key, for the next launch.
        try await waitUntil { FileManager.default.fileExists(atPath: disk.cacheFileURL(for: "k1").path) }
    }

    @Test("Pictures are made several at once, never more than the limit")
    @MainActor
    func storeMakesSeveralAtOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-previews-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gauge = Gauge()
        let store = ArtifactPreviewStore(diskCache: ThumbnailDiskCache(cacheDirectory: directory), maximumConcurrent: 3) { _ in
            await gauge.enter()
            try? await Task.sleep(for: .milliseconds(100))
            await gauge.leave()
            return NSImage(size: NSSize(width: 4, height: 4))
        }
        for index in 0..<7 {
            store.request(.page(url: URL(string: "https://ok.example/\(index)")!, kind: nil), for: "c\(index)")
        }
        try await waitUntil { (0..<7).allSatisfy { store.image(for: "c\($0)") != nil } }
        let peak = await gauge.peak
        #expect(peak == 3)
    }

    @Test("A card that leaves the screen before its turn leaves the line")
    @MainActor
    func withdrawnKeyIsNotMade() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-previews-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = Calls()
        let store = ArtifactPreviewStore(diskCache: ThumbnailDiskCache(cacheDirectory: directory), maximumConcurrent: 1) { request in
            await calls.record(request)
            try? await Task.sleep(for: .milliseconds(50))
            return NSImage(size: NSSize(width: 4, height: 4))
        }
        let first = ArtifactPreviewStore.Request.page(url: URL(string: "https://ok.example/1")!, kind: nil)
        let second = ArtifactPreviewStore.Request.page(url: URL(string: "https://ok.example/2")!, kind: nil)
        let third = ArtifactPreviewStore.Request.page(url: URL(string: "https://ok.example/3")!, kind: nil)
        store.request(first, for: "w1")
        store.request(second, for: "w2")
        store.request(third, for: "w3")
        store.withdraw("w2")
        try await waitUntil { store.image(for: "w3") != nil }
        #expect(store.image(for: "w2") == nil)
        #expect(await calls.requests == [first, third])

        // Back on screen, it is asked for again.
        store.request(second, for: "w2")
        try await waitUntil { store.image(for: "w2") != nil }
    }

    private actor Gauge {
        private var current = 0
        private(set) var peak = 0
        func enter() { current += 1; peak = max(peak, current) }
        func leave() { current -= 1 }
    }

    private actor Calls {
        private(set) var requests: [ArtifactPreviewStore.Request] = []
        var count: Int { requests.count }
        func record(_ request: ArtifactPreviewStore.Request) { requests.append(request) }
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("condition not met within \(timeout)")
    }
}
