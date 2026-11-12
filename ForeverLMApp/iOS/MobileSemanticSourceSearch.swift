import CloudKit
import Foundation
import NaturalLanguage
import OSLog

// On-device, Apple-native semantic search over sources — a lightweight iOS-only
// ranker for Siri source resolution. It ranks a small in-memory list of synced
// sources by title/subtitle and never touches the Mac's chunk embedding index, so it
// is independent of the Mac's embedding model. Uses NaturalLanguage sentence
// embeddings, so it needs no API key and no network: it ranks sources by meaning,
// catching "quiz me on the cancer vaccine talk" → "Owl Posting: cancer vaccines"
// even when no words overlap. If the embedding model is unavailable, semantic
// search fails closed instead of silently changing to a different algorithm.
//
// All methods are pure and synchronous; callers run them off the main actor (the
// per-source embedding pass is too heavy for a render/interaction path).
//
// Source vectors are memoized across calls. A synced library runs to thousands of
// sources, and re-embedding all of them on every keystroke made search cost
// seconds per query; with the cache only sources new since the last search are
// embedded, so a repeat query is a few thousand dot products.
//
// Known limitation: this ranker is English-only, and deliberately still is.
// `NLEmbedding.sentenceEmbedding` is per-language with a fixed word vocabulary —
// Dutch returns no model at all, and German and French return 640-dim vectors
// that share no space with English's 512 — so there is no per-language variant of
// this design, only a different design. The Mac's `AppleTextEmbedder` has the
// right one (`NLContextualEmbedding`, 20 Latin-script languages in a single
// cross-lingual space), but it costs 12.6 ms per title on a Mac against 5.4 ms
// here (measured), and this cache is in-memory and cold on every Siri
// launch. At thousands of sources that is a minute of dead air before Siri
// answers. Moving to it needs a persisted vector store first; until then a
// non-English topic simply ranks poorly, and the caller falls back to the
// unranked list rather than failing.
enum MobileSemanticSourceSearch {
    private static let vectorCache = VectorCache()

    /// Sources ranked by semantic similarity to `query`, best first.
    static func rank(for query: String, in sources: [MobileCloudSource], limit: Int = 20) -> [MobileCloudSource] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sources.isEmpty else { return [] }

        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english),
              let queryVector = embedding.vector(for: trimmed) else {
            return []
        }

        let scored: [(source: MobileCloudSource, score: Double)] = sources.compactMap { source in
            guard let vector = vectorCache.vector(for: source, embedding: embedding) else { return nil }
            let similarity = cosineSimilarity(queryVector, vector)
            return similarity > 0 ? (source, similarity) : nil
        }

        guard !scored.isEmpty else { return [] }
        return scored
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map(\.source)
    }

    /// Keyed by the embedded text itself, so a retitled source re-embeds and a
    /// removed one simply stops being asked for.
    private final class VectorCache: @unchecked Sendable {
        private let lock = NSLock()
        private var vectors: [String: [Double]] = [:]

        func vector(for source: MobileCloudSource, embedding: NLEmbedding) -> [Double]? {
            let text = embeddingText(for: source)

            lock.lock()
            let cached = vectors[text]
            lock.unlock()
            if let cached { return cached }

            guard let vector = embedding.vector(for: text) else { return nil }

            lock.lock()
            vectors[text] = vector
            lock.unlock()
            return vector
        }
    }

    private static func embeddingText(for source: MobileCloudSource) -> String {
        var parts = [source.title]
        if let subtitle = source.subtitle, !subtitle.isEmpty {
            parts.append(subtitle)
        }
        parts.append(source.sourceType)
        return parts.joined(separator: ". ")
    }

    private static func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, normA = 0.0, normB = 0.0
        for index in a.indices {
            dot += a[index] * b[index]
            normA += a[index] * a[index]
            normB += b[index] * b[index]
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (sqrt(normA) * sqrt(normB))
    }
}

// MARK: - The Mac's meaning and the phone's words

extension MobileSemanticSourceSearch {
    /// Sources found for `query` among `sources`, best first (docs/cloudkit-schema-design.md D27, §8a):
    /// meaning is the Mac's, its `search_sources_semantic` through the relay when the Mac can be asked,
    /// then the words of the phone's own index (`MobileTextIndex`: metadata, and the text of its text
    /// set); offline, words only. When neither finds anything, or the sync has not started, the device's
    /// title ranker above answers, so Siri and an offline phone are never left with nothing.
    static func search(for query: String, in sources: [MobileCloudSource], limit: Int = 20) async -> [MobileCloudSource] {
        let byTitles: @Sendable () async -> [MobileCloudSource] = {
            await Task.detached(priority: .userInitiated) { rank(for: query, in: sources, limit: limit) }.value
        }
        guard let session = await MobileSyncSession.startIfEnabled() else {
            return await byTitles()
        }
        async let meaning = MobileMacSearch.sourceIDs(query: query, limit: limit)
        var wordHits: [MobileTextIndex.Hit] = []
        do {
            wordHits = try await session.textIndexer.search(query, limit: limit * 2)
        } catch {
            Logger(subsystem: "com.foreverlm.mobile", category: "SemanticSourceSearch")
                .error("Searching the text index failed: \(error.localizedDescription, privacy: .public)")
        }
        let words = wordHits.map(\.sourceID)
        let found = pick(merged(meaning: await meaning ?? [], words: words), from: sources, limit: limit)
        return found.isEmpty ? await byTitles() : found
    }

    /// The Mac's answers first (meaning), then the index's (words), each source once.
    static func merged(meaning: [String], words: [String]) -> [String] {
        var seen = Set<String>()
        return (meaning + words).filter { seen.insert($0).inserted }
    }

    /// The listed sources the ids name, in the ids' order: a source the screen does not offer (hidden,
    /// outside the notebook's search) is never a result.
    static func pick(_ ids: [String], from sources: [MobileCloudSource], limit: Int) -> [MobileCloudSource] {
        let byID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Array(ids.lazy.compactMap { byID[$0] }.prefix(limit))
    }
}

/// Search by meaning on the learner's Mac, from the phone (§8a: "the Mac through the relay when
/// online"): the gateway's `POST /web/call` with `search_sources_semantic`, the tool the web's library
/// search asks too, authorized like Share's call (`MobileMacRelay`).
enum MobileMacSearch {
    /// Search waits less than Share: past it, a slow Mac gives way to the phone's own words.
    static let timeout: TimeInterval = 15

    static func request(token: String, iCloudUser: String, query: String, limit: Int) -> URLRequest {
        let body: [String: Any] = [
            "name": "search_sources_semantic",
            "arguments": ["query": query, "limit": limit],
            "icloud_user": iCloudUser,
            "icloud_environment": MobileMacRelay.environment,
        ]
        var request = URLRequest(url: MobileMacRelay.gateway.appendingPathComponent("web/call"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// The source ids an answer names, best first, each once: its result lines are
    /// `- [<type>] [<title>](foreverlm://source/<id>)` (the web reads them the same,
    /// `semanticSearchHits`). Nil when the call did not answer.
    static func sourceIDs(status: Int, body: Data) -> [String]? {
        guard case .answered(let text) = MobileMacRelay.callResult(status: status, body: body) else { return nil }
        var seen = Set<String>()
        var ids: [String] = []
        let pattern = #"^- \[[^\]]*\] \[(?:[^\]\\]|\\.)*\]\(foreverlm://source/([^)\s]+)\)"#
        for line in text.components(separatedBy: "\n") {
            guard let match = line.range(of: pattern, options: .regularExpression) else { continue }
            let link = String(line[match])
            guard let start = link.range(of: "foreverlm://source/")?.upperBound else { continue }
            let raw = String(link[start...].dropLast())
            let id = raw.removingPercentEncoding ?? raw
            if seen.insert(id).inserted { ids.append(id) }
        }
        return ids
    }

    /// The Mac's answer for `query`; nil when it cannot be asked (signed out, offline, another account).
    static func sourceIDs(query: String, limit: Int) async -> [String]? {
        guard let token = ManagedAI.requestSessionToken, let container = relayContainer,
              let user = try? await CKContainer(identifier: container).userRecordID().recordName else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(for: request(token: token, iCloudUser: user, query: query, limit: limit))
            return sourceIDs(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
        } catch {
            return nil
        }
    }

    /// The account the relay matches against the Mac's: the library container's user record name, which
    /// the Mac reports as `get_mcp_status`'s `icloud_account`. Nil in a build with no library container.
    static let relayContainer = ForeverLMRuntimeIdentity.libraryContainerIdentifier
}
